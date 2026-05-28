#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Uninstall keyremap keyboard layouts.

.DESCRIPTION
  Removes HKLM keyboard-layout registry entries pointing at DLLs listed in the
  layout manifest, removes matching HKCU preload slots, and deletes the DLLs
  from System32.
#>

[CmdletBinding()]
param(
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'

$LayoutsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
$System32 = Join-Path $env:SystemRoot 'System32'
$ProductCode = '{8776D3E2-A5D2-4D94-BFDE-7F22F4C88B4A}'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot 'data\layouts.json' }

if (Test-Path $ManifestPath) {
    $manifestJson = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $manifest = @($manifestJson | ForEach-Object { $_ })
    $targetDlls = @($manifest | ForEach-Object { [string]$_.dllName } | Where-Object { $_ } | Select-Object -Unique)
    $targetTexts = @($manifest | ForEach-Object { [string]$_.displayName } | Where-Object { $_ } | Select-Object -Unique)
} else {
    $manifest = @()
    $targetDlls = @()
    $targetTexts = @()
}

function Get-Arm64XSidecarNames {
    param([Parameter(Mandatory)][string]$DllName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($DllName)
    $armSide = if ($base.Length -le 7) { "${base}a" } else { $base.Substring(0, 6) + 'aa' }
    $x64Side = if ($base.Length -le 7) { "${base}x" } else { $base.Substring(0, 6) + 'xx' }
    return @("$armSide.dll", "$x64Side.dll")
}

$targetSidecars = @($targetDlls | ForEach-Object { Get-Arm64XSidecarNames -DllName $_ } | Select-Object -Unique)

Write-Host "Uninstalling keyremap layouts"

$entries = Get-ChildItem $LayoutsKey | Where-Object {
    try {
        $props = Get-ItemProperty $_.PSPath
        $lf = $props.'Layout File'
        $sameProduct = $props.'Layout Product Code' -eq $ProductCode -and $targetTexts -contains $props.'Layout Text'
        $sameFile = $targetDlls -contains $lf
        $sameProductFallback = $props.'Layout Product Code' -eq $ProductCode -and $targetTexts.Count -eq 0
        $sameProduct -or $sameFile -or $sameProductFallback
    } catch { $false }
}

if (-not $entries) {
    Write-Host "No HKLM registry entry references any of these DLLs. Nothing to remove."
}

$removedKlids = @()
$removedDlls = New-Object System.Collections.Generic.List[string]
foreach ($entry in $entries) {
    try {
        $lf = (Get-ItemProperty $entry.PSPath).'Layout File'
        if ($lf) { $removedDlls.Add([string]$lf) }
    } catch { }
    $removedKlids += $entry.PSChildName
    $props = Get-ItemProperty $entry.PSPath
    if ($props.'Keyremap Overrides Base KLID' -eq '1') {
        Write-Host "Restoring base HKLM key: $($entry.PSChildName)"
        foreach ($name in @('Layout File', 'Layout Text', 'Layout Display Name', 'Layout Id')) {
            $backupName = "Keyremap Original $name"
            $backup = $props.$backupName
            if ($null -ne $backup -and [string]$backup -ne '') {
                Set-ItemProperty -Path $entry.PSPath -Name $name -Value ([string]$backup) -Type String
            } else {
                Remove-ItemProperty -Path $entry.PSPath -Name $name -ErrorAction SilentlyContinue
            }
            Remove-ItemProperty -Path $entry.PSPath -Name $backupName -ErrorAction SilentlyContinue
        }
        foreach ($name in @('Layout Product Code', 'Keyremap Layout Id', 'Keyremap Overrides Base KLID')) {
            Remove-ItemProperty -Path $entry.PSPath -Name $name -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "Removing HKLM key: $($entry.PSChildName)"
        Remove-Item -Path $entry.PSPath -Recurse -Force
    }
}

# Remove HKCU preload entries that pointed at removed KLIDs
$preload = 'HKCU:\Keyboard Layout\Preload'
if (Test-Path $preload -and $removedKlids.Count -gt 0) {
    foreach ($prop in (Get-Item $preload).Property) {
        $val = (Get-ItemProperty $preload -Name $prop).$prop
        if ($removedKlids -contains $val) {
            Remove-ItemProperty -Path $preload -Name $prop
            Write-Host "Removed from user preload (slot $prop -> $val)"
        }
    }
}

# Remove modern language profile tips and substitute entries for removed layouts.
if ($removedKlids.Count -gt 0) {
    $removedLookup = @{}
    foreach ($klid in $removedKlids) { $removedLookup[$klid.ToUpperInvariant()] = $true }

    $changed = $false
    $languageList = Get-WinUserLanguageList
    foreach ($lang in $languageList) {
        $removeTips = @()
        foreach ($tip in @($lang.InputMethodTips)) {
            $parts = ([string]$tip).Split(':')
            if ($parts.Count -eq 2 -and $removedLookup.ContainsKey($parts[1].ToUpperInvariant())) {
                $removeTips += [string]$tip
            }
        }
        foreach ($tip in $removeTips) {
            [void]$lang.InputMethodTips.Remove($tip)
            Write-Host "Removed language profile input method $tip"
            $changed = $true
        }
    }
    if ($changed) { Set-WinUserLanguageList $languageList -Force }

    $substitutes = 'HKCU:\Keyboard Layout\Substitutes'
    if (Test-Path $substitutes) {
        foreach ($prop in (Get-Item $substitutes).Property) {
            $value = [string](Get-ItemProperty $substitutes -Name $prop).$prop
            if ($removedLookup.ContainsKey($value.ToUpperInvariant())) {
                Remove-ItemProperty -Path $substitutes -Name $prop
                Write-Host "Removed keyboard substitute $prop -> $value"
            }
        }
    }
}

# Delete DLLs
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class W32Delay {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 4;
}
'@ -ErrorAction SilentlyContinue

foreach ($dllName in @($targetDlls + $removedDlls | Where-Object { $_ } | Select-Object -Unique)) {
    $path = Join-Path $System32 $dllName
    if (-not (Test-Path $path)) { continue }
    try {
        Remove-Item $path -Force
        Write-Host "Removed $path"
    } catch {
        Write-Warning "Cannot delete $path (likely loaded). Scheduling for reboot."
        [void][W32Delay]::MoveFileEx($path, $null, [W32Delay]::MOVEFILE_DELAY_UNTIL_REBOOT)
    }
}

foreach ($dllName in $targetSidecars) {
    $path = Join-Path $System32 $dllName
    if (-not (Test-Path $path)) { continue }
    try {
        Remove-Item $path -Force
        Write-Host "Removed $path"
    } catch {
        Write-Warning "Cannot delete $path (likely loaded). Scheduling for reboot."
        [void][W32Delay]::MoveFileEx($path, $null, [W32Delay]::MOVEFILE_DELAY_UNTIL_REBOOT)
    }
}

Write-Host ""
Write-Host "==> Uninstall complete."

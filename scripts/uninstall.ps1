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
    $manifest = @(Get-Content $ManifestPath -Raw | ConvertFrom-Json)
    $targetDlls = @($manifest | ForEach-Object { [string]$_.dllName } | Where-Object { $_ } | Select-Object -Unique)
    $targetTexts = @($manifest | ForEach-Object { [string]$_.displayName } | Where-Object { $_ } | Select-Object -Unique)
} else {
    $targetDlls = @('kbdisdv.dll')
    $targetTexts = @('Icelandic Dvorak')
}

Write-Host "Uninstalling keyremap layouts"

$entries = Get-ChildItem $LayoutsKey | Where-Object {
    try {
        $props = Get-ItemProperty $_.PSPath
        $lf = $props.'Layout File'
        $sameProduct = $props.'Layout Product Code' -eq $ProductCode -and $targetTexts -contains $props.'Layout Text'
        $sameFile = $targetDlls -contains $lf
        $sameProduct -or $sameFile
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
    Write-Host "Removing HKLM key: $($entry.PSChildName)"
    $removedKlids += $entry.PSChildName
    Remove-Item -Path $entry.PSPath -Recurse -Force
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

Write-Host ""
Write-Host "==> Uninstall complete."

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Uninstall any Icelandic Dvorak variant(s) previously installed.

.DESCRIPTION
  Removes HKLM keyboard-layout registry entries pointing at any kbdisdv*.dll,
  removes matching HKCU preload slots, and deletes the DLLs from System32.
  Touches nothing else.

.PARAMETER Variant
  Optional. Uninstall only this one: default, caps-altgr, caps-esc, caps-ctrl.
  When omitted, all variants are removed.
#>

[CmdletBinding()]
param(
    [string]$Variant
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'variants.ps1')

$LayoutsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
$System32 = Join-Path $env:SystemRoot 'System32'

$targetDlls = if ($Variant) {
    @((Get-VariantSpec -Name $Variant).DllName)
} else {
    @(Get-VariantNames | ForEach-Object { (Get-VariantSpec -Name $_).DllName })
}

Write-Host "Uninstalling layouts that reference: $($targetDlls -join ', ')"

$entries = Get-ChildItem $LayoutsKey | Where-Object {
    try {
        $lf = (Get-ItemProperty $_.PSPath).'Layout File'
        $targetDlls -contains $lf
    } catch { $false }
}

if (-not $entries) {
    Write-Host "No HKLM registry entry references any of these DLLs. Nothing to remove."
}

$removedKlids = @()
foreach ($entry in $entries) {
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

foreach ($dllName in $targetDlls) {
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

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Uninstall the Icelandic Dvorak keyboard layout.

.DESCRIPTION
  Removes the registry entry from HKLM\SYSTEM\CurrentControlSet\Control\
  Keyboard Layouts, deletes C:\Windows\System32\kbdisdv.dll, and removes
  the layout from the current user's preload list.

  Does not touch other installed layouts.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$LayoutFile = 'kbdisdv.dll'
$LayoutsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
$System32 = Join-Path $env:SystemRoot 'System32'

# Find entries pointing at our DLL
$entries = Get-ChildItem $LayoutsKey | Where-Object {
    try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $LayoutFile } catch { $false }
}

if (-not $entries) {
    Write-Host "No registry entry references $LayoutFile. Nothing to remove from HKLM."
} else {
    foreach ($entry in $entries) {
        Write-Host "Removing HKLM key: $($entry.PSChildName)"
        Remove-Item -Path $entry.PSPath -Recurse -Force
    }
}

# Remove from current user preload
$preload = 'HKCU:\Keyboard Layout\Preload'
if (Test-Path $preload) {
    $klids = $entries | ForEach-Object { $_.PSChildName }
    foreach ($prop in (Get-Item $preload).Property) {
        $val = (Get-ItemProperty $preload -Name $prop).$prop
        if ($klids -contains $val) {
            Remove-ItemProperty -Path $preload -Name $prop
            Write-Host "Removed from user preload (slot $prop -> $val)"
        }
    }
}

# Remove DLL
$dll = Join-Path $System32 $LayoutFile
if (Test-Path $dll) {
    try {
        Remove-Item $dll -Force
        Write-Host "Removed $dll"
    } catch {
        Write-Warning "Could not delete $dll (likely in use). It will be removed on next reboot. Error: $_"
        # Schedule for delete-on-reboot via MoveFileEx
        $moveFile = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@ -Name MFE -Namespace W32 -PassThru
        $null = $moveFile::MoveFileEx($dll, $null, 4)  # MOVEFILE_DELAY_UNTIL_REBOOT
        Write-Host "Scheduled for delete-on-reboot."
    }
}

Write-Host ""
Write-Host "==> Uninstall complete. Sign out / reboot to fully release the DLL."

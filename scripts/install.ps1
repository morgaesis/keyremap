#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install the Icelandic Dvorak keyboard layout DLL system-wide.

.DESCRIPTION
  Copies kbdisdv.dll into C:\Windows\System32\, registers it under
  HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts with an unused
  Layout Id, and (optionally) adds it to the user's preloaded input
  languages so it shows up in Win+Space layout switcher immediately.

  After install: sign out and back in (or reboot) for Windows to pick up
  the new DLL fully. The layout will then appear in Settings → Time &
  language → Language & region → Icelandic → Options, and is selectable
  via Win+Space.

.PARAMETER DllPath
  Path to kbdisdv.dll (built by scripts\build.ps1 or downloaded from a
  GitHub release). Defaults to build\arm64\kbdisdv.dll.

.PARAMETER AddToCurrentUser
  Add this layout to the current user's preloaded input list. Default: true.

.PARAMETER Force
  Reinstall even if an entry already exists (overwrites DLL and registry).

.EXAMPLE
  .\scripts\install.ps1
  .\scripts\install.ps1 -DllPath .\artifacts\arm64\kbdisdv.dll -Force
#>

[CmdletBinding()]
param(
    [string]$DllPath,
    [bool]$AddToCurrentUser = $true,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DllPath) {
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x64' }
        'Arm64' { 'arm64' }
        'X86'   { 'x86' }
        default { throw "Unsupported OS architecture: $_" }
    }
    $DllPath = Join-Path $RepoRoot "build\$arch\kbdisdv.dll"
}
if (-not (Test-Path $DllPath)) {
    throw "DLL not found at $DllPath. Build with scripts\build.ps1 or download a release asset."
}

# --- Constants -----------------------------------------------------------------
$LayoutFile = 'kbdisdv.dll'
$LayoutText = 'Icelandic Dvorak'
$BaseLangId = '040f'            # Icelandic (is-IS) base language
$LayoutsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
$System32 = Join-Path $env:SystemRoot 'System32'

# --- Pick an unused Layout Id (top byte 'axxx' for custom layouts) -------------
function Get-AvailableLayoutId {
    # Windows convention: custom layout KLIDs use the last 4 hex digits as
    # Layout Id. Scan existing keys for collisions.
    $existingKlids = Get-ChildItem $LayoutsKey | ForEach-Object { $_.PSChildName }
    for ($id = 0xa000; $id -lt 0xffff; $id++) {
        $candidate = ('{0:x4}{1}' -f $id, $BaseLangId)
        if ($existingKlids -notcontains $candidate) { return $candidate }
    }
    throw "No free Layout Id in range a000..ffff (really?)"
}

# Re-use an existing entry for this layout if present
$existing = Get-ChildItem $LayoutsKey | Where-Object {
    try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $LayoutFile } catch { $false }
}

if ($existing -and -not $Force) {
    Write-Host "Layout already registered as KLID $($existing.PSChildName). Use -Force to overwrite."
    $klid = $existing.PSChildName
} else {
    if ($existing -and $Force) {
        $klid = $existing.PSChildName
        Write-Host "Overwriting existing KLID: $klid"
    } else {
        $klid = Get-AvailableLayoutId
        Write-Host "Allocated new KLID: $klid"
    }
}

# --- Copy DLL into System32 ----------------------------------------------------
$dest = Join-Path $System32 $LayoutFile
Write-Host "Copying $DllPath -> $dest"
Copy-Item -Path $DllPath -Destination $dest -Force

# --- Register in registry ------------------------------------------------------
$keyPath = Join-Path $LayoutsKey $klid
if (-not (Test-Path $keyPath)) {
    New-Item -Path $LayoutsKey -Name $klid -Force | Out-Null
}

# Layout Id must be a unique 4-digit hex string for the "custom layout" feature
# to work across language bar preloads. Derived from the upper half of KLID.
$layoutIdHex = $klid.Substring(0, 4)

Set-ItemProperty -Path $keyPath -Name 'Layout File' -Value $LayoutFile -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Text' -Value $LayoutText -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Display Name' -Value "@%SystemRoot%\system32\$LayoutFile,-1000" -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Id' -Value $layoutIdHex -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Product Code' -Value '{8776D3E2-A5D2-4D94-BFDE-7F22F4C88B4A}' -Type String

Write-Host "Registered at $keyPath"

# --- Add to current user's preload list (optional) -----------------------------
if ($AddToCurrentUser) {
    $preload = 'HKCU:\Keyboard Layout\Preload'
    if (-not (Test-Path $preload)) { New-Item -Path $preload -Force | Out-Null }
    $existingNums = (Get-Item $preload).Property | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $maxNum = if ($existingNums) { ($existingNums | Measure-Object -Maximum).Maximum } else { 0 }
    $slot = ($maxNum + 1).ToString()
    $alreadyPreloaded = (Get-Item $preload).Property | ForEach-Object {
        (Get-ItemProperty $preload -Name $_).$_
    } | Where-Object { $_ -eq $klid }
    if (-not $alreadyPreloaded) {
        Set-ItemProperty -Path $preload -Name $slot -Value $klid -Type String
        Write-Host "Added to current user preload (slot $slot)"
    } else {
        Write-Host "Already in current user preload list"
    }
}

Write-Host ""
Write-Host "==> Install complete."
Write-Host "    Sign out and back in (or reboot) to activate."
Write-Host "    After that: Win+Space to switch layouts, or Settings → Time & language → Language."

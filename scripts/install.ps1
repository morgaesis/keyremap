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

# --- Pick an unused KLID and Layout Id -----------------------------------------
# KLID is the registry key name (8 hex chars: upper 4 = vendor/variant, lower 4
# = language id). Layout Id is a separate 4-hex-char value that must be unique
# across ALL installed keyboards system-wide (Windows tracks layouts by this
# value internally — collisions silently break selection).
function Get-AvailableLayoutIds {
    $existing = Get-ChildItem $LayoutsKey
    $existingKlids = $existing | ForEach-Object { $_.PSChildName }
    $existingLayoutIds = @{}
    foreach ($k in $existing) {
        try {
            $id = (Get-ItemProperty $k.PSPath -Name 'Layout Id' -ErrorAction Stop).'Layout Id'
            if ($id) { $existingLayoutIds[$id.ToLower()] = $true }
        } catch { }
    }

    # KLIDs for custom layouts conventionally start at 0xa000 in the upper half.
    # Layout Id space is 0001..FFFF; default layouts use ~0001..0070, so start
    # at 0x00a0 to stay clear of both reserved values and common user layouts.
    $klid = $null
    for ($hi = 0xa000; $hi -lt 0xffff; $hi++) {
        $candidate = ('{0:x4}{1}' -f $hi, $BaseLangId)
        if ($existingKlids -notcontains $candidate) { $klid = $candidate; break }
    }
    if (-not $klid) { throw "No free KLID available in range a000..ffff" }

    $layoutId = $null
    for ($id = 0x00a0; $id -le 0xffff; $id++) {
        $candidate = ('{0:x4}' -f $id)
        if (-not $existingLayoutIds.ContainsKey($candidate)) { $layoutId = $candidate; break }
    }
    if (-not $layoutId) { throw "No free Layout Id available in range 00a0..ffff" }

    return @{ Klid = $klid; LayoutId = $layoutId }
}

# Re-use an existing entry for this layout if present
$existing = Get-ChildItem $LayoutsKey | Where-Object {
    try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $LayoutFile } catch { $false }
}

if ($existing -and -not $Force) {
    Write-Host "Layout already registered as KLID $($existing.PSChildName). Use -Force to overwrite."
    $klid = $existing.PSChildName
    $layoutIdHex = (Get-ItemProperty $existing.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
    if (-not $layoutIdHex) { $layoutIdHex = (Get-AvailableLayoutIds).LayoutId }
} else {
    if ($existing -and $Force) {
        $klid = $existing.PSChildName
        $layoutIdHex = (Get-ItemProperty $existing.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
        if (-not $layoutIdHex) { $layoutIdHex = (Get-AvailableLayoutIds).LayoutId }
        Write-Host "Overwriting existing KLID: $klid (Layout Id: $layoutIdHex)"
    } else {
        $ids = Get-AvailableLayoutIds
        $klid = $ids.Klid
        $layoutIdHex = $ids.LayoutId
        Write-Host "Allocated new KLID: $klid, Layout Id: $layoutIdHex"
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

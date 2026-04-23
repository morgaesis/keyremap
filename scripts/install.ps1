#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install the Icelandic Dvorak keyboard layout DLL system-wide.

.DESCRIPTION
  Picks a CapsLock behavior variant (default / AltGr / Esc / Ctrl), copies
  the matching DLL into System32, registers it under HKLM's keyboard layout
  list, adds it to the current user's input preload, and calls
  LoadKeyboardLayoutW so Windows activates it without requiring sign-out.

  After install:
    Win+Space should list "Icelandic Dvorak" (or the variant's display name)
    immediately. If not, sign out and back in.

.PARAMETER DllPath
  Path to the DLL. Defaults to build\<arch>\<variant-dll-name> based on the
  running OS architecture and -CapsAction.

.PARAMETER CapsAction
  What the CapsLock key does:
    None   — CapsLock stays CapsLock (kbdisdv.dll)
    AltGr  — CapsLock is a second AltGr (kbdisdv-caps-altgr.dll)
    Esc    — CapsLock is Escape (kbdisdv-caps-esc.dll)
    Ctrl   — CapsLock is Left Control (kbdisdv-caps-ctrl.dll)

.PARAMETER AddToCurrentUser
  Add to current user's preload so it shows in Win+Space. Default: true.

.PARAMETER Force
  Reinstall even if an entry already exists.
#>

[CmdletBinding()]
param(
    [string]$DllPath,

    [ValidateSet('None', 'AltGr', 'Esc', 'Ctrl')]
    [string]$CapsAction = 'None',

    [bool]$AddToCurrentUser = $true,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'variants.ps1')

# Map CapsAction to variant
$variantName = switch ($CapsAction) {
    'None'  { 'default' }
    'AltGr' { 'caps-altgr' }
    'Esc'   { 'caps-esc' }
    'Ctrl'  { 'caps-ctrl' }
}
$spec = Get-VariantSpec -Name $variantName

if (-not $DllPath) {
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x64' }
        'Arm64' { 'arm64' }
        'X86'   { 'x86' }
        default { throw "Unsupported OS architecture: $_" }
    }
    $DllPath = Join-Path $RepoRoot "build\$arch\$($spec.DllName)"
}
if (-not (Test-Path $DllPath)) {
    throw "DLL not found at $DllPath. Build with scripts\build.ps1 -Arch <arch> -Variant $variantName, or download a release asset."
}

$LayoutFile  = $spec.DllName
$LayoutText  = $spec.DisplayName
$BaseLangId  = '040f'
$LayoutsKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
$System32    = Join-Path $env:SystemRoot 'System32'
$ProductCode = '{8776D3E2-A5D2-4D94-BFDE-7F22F4C88B4A}'

# --- Pick unused KLID + Layout Id ---------------------------------------------
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

# Find entry already pointing at this variant's DLL
$existing = Get-ChildItem $LayoutsKey | Where-Object {
    try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $LayoutFile } catch { $false }
}

if ($existing -and -not $Force) {
    Write-Host "Variant '$variantName' already registered as KLID $($existing.PSChildName). Use -Force to overwrite."
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
        Write-Host "Allocated new KLID: $klid, Layout Id: $layoutIdHex (variant: $variantName)"
    }
}

# --- Copy DLL ------------------------------------------------------------------
$dest = Join-Path $System32 $LayoutFile
Write-Host "Copying $DllPath -> $dest"
Copy-Item -Path $DllPath -Destination $dest -Force

# --- Registry -----------------------------------------------------------------
$keyPath = Join-Path $LayoutsKey $klid
if (-not (Test-Path $keyPath)) {
    New-Item -Path $LayoutsKey -Name $klid -Force | Out-Null
}
Set-ItemProperty -Path $keyPath -Name 'Layout File' -Value $LayoutFile -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Text' -Value $LayoutText -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Display Name' -Value "@%SystemRoot%\system32\$LayoutFile,-1000" -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Id' -Value $layoutIdHex -Type String
Set-ItemProperty -Path $keyPath -Name 'Layout Product Code' -Value $ProductCode -Type String
Write-Host "Registered at $keyPath"

# --- Current user preload -----------------------------------------------------
if ($AddToCurrentUser) {
    $preload = 'HKCU:\Keyboard Layout\Preload'
    if (-not (Test-Path $preload)) { New-Item -Path $preload -Force | Out-Null }
    $alreadyPreloaded = (Get-Item $preload).Property | ForEach-Object {
        (Get-ItemProperty $preload -Name $_).$_
    } | Where-Object { $_ -eq $klid }
    if (-not $alreadyPreloaded) {
        $existingNums = (Get-Item $preload).Property | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        $maxNum = if ($existingNums) { ($existingNums | Measure-Object -Maximum).Maximum } else { 0 }
        $slot = ($maxNum + 1).ToString()
        Set-ItemProperty -Path $preload -Name $slot -Value $klid -Type String
        Write-Host "Added to current user preload (slot $slot)"
    } else {
        Write-Host "Already in current user preload list"
    }
}

# --- Live activation (no sign-out required) -----------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KbdActivate {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint Flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    public const uint KLF_ACTIVATE      = 0x00000001;
    public const uint KLF_SUBSTITUTE_OK = 0x00000002;
    public const uint KLF_REORDER       = 0x00000008;
    public const uint WM_INPUTLANGCHANGEREQUEST = 0x0050;
    public const uint WM_SETTINGCHANGE          = 0x001A;
    public static readonly IntPtr HWND_BROADCAST = (IntPtr)0xFFFF;
    public const uint SMTO_ABORTIFHUNG = 0x0002;
}
'@ -ErrorAction SilentlyContinue

try {
    $hkl = [KbdActivate]::LoadKeyboardLayout(
        $klid,
        [KbdActivate]::KLF_ACTIVATE -bor [KbdActivate]::KLF_SUBSTITUTE_OK -bor [KbdActivate]::KLF_REORDER)
    if ($hkl -eq [IntPtr]::Zero) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Warning "LoadKeyboardLayout returned NULL (error $code). You may need to sign out."
    } else {
        Write-Host ("LoadKeyboardLayout OK (HKL=0x{0:X})" -f $hkl.ToInt64())
    }
    $result = [UIntPtr]::Zero
    [void][KbdActivate]::SendMessageTimeout(
        [KbdActivate]::HWND_BROADCAST,
        [KbdActivate]::WM_INPUTLANGCHANGEREQUEST,
        [UIntPtr]::Zero, $hkl,
        [KbdActivate]::SMTO_ABORTIFHUNG, 2000,
        [ref]$result)
    [void][KbdActivate]::SendMessageTimeout(
        [KbdActivate]::HWND_BROADCAST,
        [KbdActivate]::WM_SETTINGCHANGE,
        [UIntPtr]::Zero, [IntPtr]::Zero,
        [KbdActivate]::SMTO_ABORTIFHUNG, 2000,
        [ref]$result)
    Write-Host "Broadcast WM_INPUTLANGCHANGEREQUEST / WM_SETTINGCHANGE."
} catch {
    Write-Warning "Live activation failed: $_. Sign out and back in if needed."
}

Write-Host ""
Write-Host "==> Install complete: $LayoutText ($variantName)"
Write-Host "    Win+Space should list it now."

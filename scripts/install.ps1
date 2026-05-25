#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install selected keyremap keyboard layout DLLs system-wide.

.DESCRIPTION
  Copies selected layout DLLs into System32, registers them under HKLM's
  keyboard layout list, adds them to the current user's input preload, and
  calls LoadKeyboardLayoutW so Windows can activate them without requiring
  sign-out.

  After install:
    Win+Space should list "Icelandic Dvorak" immediately. If not, sign out
    and back in.

.PARAMETER AddToCurrentUser
  Add to current user's preload so it shows in Win+Space. Default: true.

.PARAMETER Force
  Reinstall even if an entry already exists.
#>

[CmdletBinding()]
param(
    [string[]]$LayoutId,

    [string]$SelectionFile,

    [string]$ManifestPath,

    [string]$DllPath,

    [bool]$AddToCurrentUser = $true,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot 'data\layouts.json' }
if (-not (Test-Path $ManifestPath)) { throw "Layout manifest not found: $ManifestPath" }

if ($SelectionFile) {
    if (-not (Test-Path $SelectionFile)) { throw "Selection file not found: $SelectionFile" }
    $LayoutId += @(Get-Content $SelectionFile | Where-Object { $_ -and $_.Trim() })
}
if (-not $LayoutId -or $LayoutId.Count -eq 0) { $LayoutId = @('is-dvorak') }
$LayoutId = @($LayoutId | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$layoutsById = @{}
foreach ($layout in $manifest) { $layoutsById[[string]$layout.id] = $layout }

$osArch = try {
    (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).OSArchitecture
} catch {
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
}
$arch = switch -Regex ($osArch) {
    'ARM\s*64|Arm64' {
        # Plain ARM64 keyboard DLLs cannot be loaded by x64-compatible hosts.
        # Until ARM64EC/ARM64X builds are produced, prefer x64 on Windows ARM.
        'x64'
        break
    }
    '64|X64' { 'x64'; break }
    '32|X86' { 'x86'; break }
    default { throw "Unsupported OS architecture: $osArch" }
}

$LayoutsKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
$System32    = Join-Path $env:SystemRoot 'System32'
$ProductCode = '{8776D3E2-A5D2-4D94-BFDE-7F22F4C88B4A}'

function Get-LayoutPayloadName {
    param(
        [Parameter(Mandatory)][string]$SourceDll,
        [Parameter(Mandatory)][string]$OriginalDllName
    )

    $hash = (Get-FileHash -LiteralPath $SourceDll -Algorithm SHA256).Hash.ToLowerInvariant()
    $prefix = [System.IO.Path]::GetFileNameWithoutExtension($OriginalDllName).ToLowerInvariant()
    $prefix = ($prefix -replace '[^a-z0-9]', '')
    if ($prefix.Length -gt 3) { $prefix = $prefix.Substring(0, 3) }
    if ($prefix.Length -eq 0) { $prefix = 'kbd' }
    return ('{0}{1}.dll' -f $prefix, $hash.Substring(0, 8 - $prefix.Length))
}

function Get-InstalledLayoutEntries {
    param(
        [Parameter(Mandatory)][string]$LayoutText,
        [Parameter(Mandatory)][string[]]$LayoutFiles
    )

    Get-ChildItem $LayoutsKey | Where-Object {
        try {
            $props = Get-ItemProperty $_.PSPath
            $sameProduct = $props.'Layout Product Code' -eq $ProductCode -and $props.'Layout Text' -eq $LayoutText
            $sameFile = $LayoutFiles -contains $props.'Layout File'
            $sameProduct -or $sameFile
        } catch {
            $false
        }
    }
}

function Remove-PreloadKlids {
    param([Parameter(Mandatory)][string[]]$Klids)

    $preload = 'HKCU:\Keyboard Layout\Preload'
    if (-not (Test-Path $preload)) { return }
    foreach ($prop in (Get-Item $preload).Property) {
        $val = (Get-ItemProperty $preload -Name $prop).$prop
        if ($Klids -contains $val) {
            Remove-ItemProperty -Path $preload -Name $prop
            Write-Host "Removed stale preload entry (slot $prop -> $val)"
        }
    }
}

# --- Pick unused KLID + Layout Id ---------------------------------------------
function Get-AvailableLayoutIds {
    param([Parameter(Mandatory)][string]$BaseLangId)

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

function Install-OneLayout {
    param([Parameter(Mandatory)]$Layout)

    $LayoutFile = [string]$Layout.dllName
    $LayoutText = [string]$Layout.displayName
    $BaseLangId = [string]$Layout.baseLangId
    if (-not $LayoutFile -or -not $LayoutText -or -not $BaseLangId) {
        throw "Manifest entry '$($Layout.id)' is missing dllName/displayName/baseLangId"
    }

    $sourceDll = if ($DllPath -and $LayoutId.Count -eq 1) {
        $DllPath
    } else {
        Join-Path $RepoRoot "build\$arch\$LayoutFile"
    }
    if (-not (Test-Path $sourceDll)) {
        throw "DLL not found for '$($Layout.id)' at $sourceDll. This layout is listed but not packaged for $arch yet."
    }

    $payloadFile = Get-LayoutPayloadName -SourceDll $sourceDll -OriginalDllName $LayoutFile
    $existing = @(Get-InstalledLayoutEntries -LayoutText $LayoutText -LayoutFiles @($LayoutFile, $payloadFile))
    $matchingPayload = @($existing | Where-Object {
        try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $payloadFile } catch { $false }
    } | Select-Object -First 1)

    if ($existing -and -not $Force) {
        $entry = if ($matchingPayload) { $matchingPayload[0] } else { $existing[0] }
        Write-Host "$LayoutText already registered as KLID $($entry.PSChildName). Use -Force to overwrite."
        $klid = $entry.PSChildName
        $layoutIdHex = (Get-ItemProperty $entry.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
        if (-not $layoutIdHex) { $layoutIdHex = (Get-AvailableLayoutIds -BaseLangId $BaseLangId).LayoutId }
    } else {
        if ($matchingPayload -and $Force) {
            $klid = $matchingPayload[0].PSChildName
            $layoutIdHex = (Get-ItemProperty $matchingPayload[0].PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
            if (-not $layoutIdHex) { $layoutIdHex = (Get-AvailableLayoutIds -BaseLangId $BaseLangId).LayoutId }
            Write-Host "Refreshing existing KLID: $klid (Layout Id: $layoutIdHex)"
        } else {
            $ids = Get-AvailableLayoutIds -BaseLangId $BaseLangId
            $klid = $ids.Klid
            $layoutIdHex = $ids.LayoutId
            Write-Host "Allocated new KLID: $klid, Layout Id: $layoutIdHex"
        }
    }

    $dest = Join-Path $System32 $payloadFile
    Write-Host "Copying $sourceDll -> $dest"
    Copy-Item -Path $sourceDll -Destination $dest -Force

    $staleEntries = @($existing | Where-Object { $_.PSChildName -ne $klid })
    if ($staleEntries.Count -gt 0) {
        $staleKlids = @($staleEntries | ForEach-Object { $_.PSChildName })
        Remove-PreloadKlids -Klids $staleKlids
        foreach ($entry in $staleEntries) {
            Write-Host "Removing stale HKLM key: $($entry.PSChildName)"
            Remove-Item -Path $entry.PSPath -Recurse -Force
        }
    }

    $keyPath = Join-Path $LayoutsKey $klid
    if (-not (Test-Path $keyPath)) {
        New-Item -Path $LayoutsKey -Name $klid -Force | Out-Null
    }
    Set-ItemProperty -Path $keyPath -Name 'Layout File' -Value $payloadFile -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Text' -Value $LayoutText -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Display Name' -Value "@%SystemRoot%\system32\$payloadFile,-1000" -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Id' -Value $layoutIdHex -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Product Code' -Value $ProductCode -Type String
    Write-Host "Registered at $keyPath"

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

    return $klid
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

$installedKlids = @()
foreach ($id in $LayoutId) {
    if (-not $layoutsById.ContainsKey($id)) { throw "Unknown layout id '$id' in manifest $ManifestPath" }
    $layout = $layoutsById[$id]
    if (-not [bool]$layout.packaged) { throw "Layout '$id' is not packaged yet." }
    $installedKlids += Install-OneLayout -Layout $layout
}

foreach ($klid in $installedKlids) {
    try {
        $hkl = [KbdActivate]::LoadKeyboardLayout(
            $klid,
            [KbdActivate]::KLF_ACTIVATE -bor [KbdActivate]::KLF_SUBSTITUTE_OK -bor [KbdActivate]::KLF_REORDER)
        if ($hkl -eq [IntPtr]::Zero) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Warning "LoadKeyboardLayout($klid) returned NULL (error $code). You may need to sign out."
        } else {
            Write-Host ("LoadKeyboardLayout OK for {0} (HKL=0x{1:X})" -f $klid, $hkl.ToInt64())
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
    } catch {
        Write-Warning "Live activation failed for ${klid}: $_. Sign out and back in if needed."
    }
}

Write-Host ""
Write-Host "==> Install complete: $($LayoutId -join ', ')"
Write-Host "    Win+Space should list installed layouts now."

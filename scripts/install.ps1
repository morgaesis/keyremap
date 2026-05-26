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

function Get-LayoutHashHighWord {
    param([Parameter(Mandatory)][string]$SourceDll)

    $hash = (Get-FileHash -LiteralPath $SourceDll -Algorithm SHA256).Hash.ToLowerInvariant()
    $seed = [Convert]::ToInt32($hash.Substring(0, 4), 16)
    return 0xb000 + ($seed % 0x3000)
}

function Get-LayoutHashLayoutId {
    param([Parameter(Mandatory)][string]$SourceDll)

    $hash = (Get-FileHash -LiteralPath $SourceDll -Algorithm SHA256).Hash.ToLowerInvariant()
    $seed = [Convert]::ToInt32($hash.Substring(4, 4), 16)
    return 0x1000 + ($seed % 0xefff)
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

function Resolve-LanguageTag {
    param([Parameter(Mandatory)][string]$BaseLangId)

    $lcid = [Convert]::ToInt32($BaseLangId, 16)
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($lcid)
        if ($culture.Name) { return $culture.Name }
    } catch {
        Write-Warning "Could not derive a Windows language tag from LANGID ${BaseLangId}: $_"
    }
    return $null
}

function Remove-StaleUserLanguageTips {
    param(
        [Parameter(Mandatory)][string]$BaseLangId,
        [string[]]$StaleKlids = @()
    )

    $base = $BaseLangId.ToUpperInvariant()
    $stale = @{}
    foreach ($klid in $StaleKlids) {
        if ($klid) { $stale[$klid.ToUpperInvariant()] = $true }
    }

    $changed = $false
    $list = Get-WinUserLanguageList
    foreach ($lang in $list) {
        $remove = @()
        foreach ($tip in @($lang.InputMethodTips)) {
            $parts = ([string]$tip).Split(':')
            if ($parts.Count -ne 2) { continue }
            $keyboard = $parts[1].ToUpperInvariant()
            $keyPath = Join-Path $LayoutsKey $keyboard.ToLowerInvariant()
            $isGenerated = $keyboard -match "^[A-D][0-9A-F]{3}$base$"
            $isKnownStale = $stale.ContainsKey($keyboard)
            $isDanglingGenerated = $isGenerated -and -not (Test-Path $keyPath)
            if ($isKnownStale -or $isDanglingGenerated) { $remove += [string]$tip }
        }
        foreach ($tip in $remove) {
            [void]$lang.InputMethodTips.Remove($tip)
            Write-Host "Removed stale language profile input method $tip from $($lang.LanguageTag)"
            $changed = $true
        }
    }

    if ($changed) { Set-WinUserLanguageList $list -Force }
}

function Add-UserLanguageTip {
    param(
        [Parameter(Mandatory)][string]$LanguageTag,
        [Parameter(Mandatory)][string]$BaseLangId,
        [Parameter(Mandatory)][string]$Klid
    )

    $targetTip = ('{0}:{1}' -f $BaseLangId.ToUpperInvariant(), $Klid.ToUpperInvariant())
    $list = Get-WinUserLanguageList
    $changed = $false
    $emptyProfiles = @()
    foreach ($profile in $list) {
        $remove = @()
        foreach ($tip in @($profile.InputMethodTips)) {
            $parts = ([string]$tip).Split(':')
            if ($parts.Count -eq 2 -and $parts[1].Equals($Klid, [System.StringComparison]::OrdinalIgnoreCase) -and $profile.LanguageTag -ne $LanguageTag) {
                $remove += [string]$tip
            }
        }
        foreach ($tip in $remove) {
            [void]$profile.InputMethodTips.Remove($tip)
            Write-Host "Removed relocated input method $tip from $($profile.LanguageTag)"
            $changed = $true
        }
        if ($remove.Count -gt 0 -and $profile.InputMethodTips.Count -eq 0) { $emptyProfiles += $profile }
    }
    foreach ($profile in $emptyProfiles) {
        [void]$list.Remove($profile)
        Write-Host "Removed empty language profile: $($profile.LanguageTag)"
    }

    $lang = $null
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i].LanguageTag -eq $LanguageTag) { $lang = $list[$i]; break }
    }
    if (-not $lang) {
        $prefix = $BaseLangId.ToUpperInvariant() + ':'
        for ($i = 0; $i -lt $list.Count; $i++) {
            $hasSameBase = @($list[$i].InputMethodTips | Where-Object { ([string]$_).ToUpperInvariant().StartsWith($prefix) }).Count -gt 0
            if ($hasSameBase) { $lang = $list[$i]; break }
        }
    }
    if (-not $lang) {
        $newList = New-WinUserLanguageList $LanguageTag
        $lang = $newList[0]
        $lang.InputMethodTips.Clear()
        $list.Add($lang)
        Write-Host "Added user language profile: $LanguageTag"
        $changed = $true
    }

    if (-not ($lang.InputMethodTips -contains $targetTip)) {
        [void]$lang.InputMethodTips.Add($targetTip)
        Write-Host "Added user language input method: $targetTip"
        $changed = $true
    } else {
        Write-Host "User language input method already present: $targetTip"
    }
    $baseTip = ('{0}:0000{0}' -f $BaseLangId.ToUpperInvariant())
    if ($lang.InputMethodTips.Count -eq 2 -and
        ($lang.InputMethodTips -contains $targetTip) -and
        ($lang.InputMethodTips -contains $baseTip)) {
        [void]$lang.InputMethodTips.Remove($baseTip)
        Write-Host "Removed auto-added base input method: $baseTip"
        $changed = $true
    }
    if ($changed) { Set-WinUserLanguageList $list -Force }
}

function Remove-ProjectSubstitutes {
    param(
        [Parameter(Mandatory)][string]$BaseLangId,
        [string[]]$AllowedKlids = @(),
        [string[]]$StaleKlids = @()
    )

    $substitutes = 'HKCU:\Keyboard Layout\Substitutes'
    if (-not (Test-Path $substitutes)) { return }
    $allowed = @{}
    foreach ($klid in $AllowedKlids) {
        if ($klid) { $allowed[$klid.ToLowerInvariant()] = $true }
    }
    $stale = @{}
    foreach ($klid in $StaleKlids) {
        if ($klid) { $stale[$klid.ToLowerInvariant()] = $true }
    }

    foreach ($prop in (Get-Item $substitutes).Property) {
        $value = (Get-ItemProperty $substitutes -Name $prop).$prop
        $propString = [string]$prop
        $valueString = [string]$value
        $propLower = $propString.ToLowerInvariant()
        $valueLower = $valueString.ToLowerInvariant()
        $valueIsStale = $stale.ContainsKey($valueLower)
        $propIsStale = $stale.ContainsKey($propLower)
        $isWrongBaseRedirect = $propIsStale -and $valueString -eq "0000$BaseLangId"
        $isWrongGeneratedRedirect = $propIsStale -and $allowed.ContainsKey($valueLower)
        if ($valueIsStale -or $isWrongBaseRedirect -or $isWrongGeneratedRedirect) {
            Remove-ItemProperty -Path $substitutes -Name $propString
            Write-Host "Removed stale keyboard substitute $propString -> $valueString"
        }
    }
}

# --- Pick unused KLID + Layout Id ---------------------------------------------
function Get-AvailableLayoutIds {
    param(
        [Parameter(Mandatory)][string]$BaseLangId,
        [int]$PreferredHighWord = -1,
        [int]$PreferredLayoutId = -1
    )

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
    if ($PreferredHighWord -ge 0xa000 -and $PreferredHighWord -lt 0xffff) {
        $candidate = ('{0:x4}{1}' -f $PreferredHighWord, $BaseLangId)
        if ($existingKlids -notcontains $candidate) { $klid = $candidate }
    }
    for ($hi = 0xa000; $hi -lt 0xffff; $hi++) {
        if ($klid) { break }
        $candidate = ('{0:x4}{1}' -f $hi, $BaseLangId)
        if ($existingKlids -notcontains $candidate) { $klid = $candidate; break }
    }
    if (-not $klid) { throw "No free KLID available in range a000..ffff" }

    $layoutId = $null
    if ($PreferredLayoutId -ge 0x00a0 -and $PreferredLayoutId -le 0xffff) {
        $candidate = ('{0:x4}' -f $PreferredLayoutId)
        if (-not $existingLayoutIds.ContainsKey($candidate)) { $layoutId = $candidate }
    }
    for ($id = 0x00a0; $id -le 0xffff; $id++) {
        if ($layoutId) { break }
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
    $LanguageTag = [string]$Layout.languageTag
    if (-not $LayoutFile -or -not $LayoutText -or -not $BaseLangId) {
        throw "Manifest entry '$($Layout.id)' is missing dllName/displayName/baseLangId"
    }
    if (-not $LanguageTag) { $LanguageTag = Resolve-LanguageTag -BaseLangId $BaseLangId }

    $sourceDll = if ($DllPath -and $LayoutId.Count -eq 1) {
        $DllPath
    } else {
        Join-Path $RepoRoot "build\$arch\$LayoutFile"
    }
    if (-not (Test-Path $sourceDll)) {
        throw "DLL not found for '$($Layout.id)' at $sourceDll. This layout is listed but not packaged for $arch yet."
    }

    $payloadFile = Get-LayoutPayloadName -SourceDll $sourceDll -OriginalDllName $LayoutFile
    $preferredHighWord = Get-LayoutHashHighWord -SourceDll $sourceDll
    $preferredLayoutId = Get-LayoutHashLayoutId -SourceDll $sourceDll
    $preferredLayoutIdHex = ('{0:x4}' -f $preferredLayoutId)
    $preferredKlid = ('{0:x4}{1}' -f $preferredHighWord, $BaseLangId)
    $existing = @(Get-InstalledLayoutEntries -LayoutText $LayoutText -LayoutFiles @($LayoutFile, $payloadFile))
    $matchingPayload = @($existing | Where-Object {
        try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $payloadFile } catch { $false }
    } | Select-Object -First 1)
    $matchingPreferredPayload = @($matchingPayload | Where-Object { $_.PSChildName -eq $preferredKlid } | Select-Object -First 1)
    $staleKlids = @($existing | ForEach-Object { $_.PSChildName })

    if ($existing -and -not $Force) {
        $entry = if ($matchingPayload) { $matchingPayload[0] } else { $existing[0] }
        Write-Host "$LayoutText already registered as KLID $($entry.PSChildName). Use -Force to overwrite."
        $klid = $entry.PSChildName
        $layoutIdHex = (Get-ItemProperty $entry.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
        if (-not $layoutIdHex) { $layoutIdHex = (Get-AvailableLayoutIds -BaseLangId $BaseLangId).LayoutId }
    } else {
        if ($matchingPreferredPayload -and $Force) {
            $klid = $matchingPreferredPayload[0].PSChildName
            $layoutIdHex = $preferredLayoutIdHex
            Write-Host "Refreshing existing KLID: $klid (Layout Id: $layoutIdHex)"
        } else {
            $ids = Get-AvailableLayoutIds -BaseLangId $BaseLangId -PreferredHighWord $preferredHighWord -PreferredLayoutId $preferredLayoutId
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
    Set-ItemProperty -Path $keyPath -Name 'Layout Display Name' -Value $LayoutText -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Id' -Value $layoutIdHex -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Product Code' -Value $ProductCode -Type String
    Write-Host "Registered at $keyPath"

    if ($AddToCurrentUser) {
        Remove-PreloadKlids -Klids $staleKlids
        Remove-StaleUserLanguageTips -BaseLangId $BaseLangId -StaleKlids $staleKlids
        Remove-ProjectSubstitutes -BaseLangId $BaseLangId -AllowedKlids @($klid) -StaleKlids $staleKlids
        if ($LanguageTag) {
            Add-UserLanguageTip -LanguageTag $LanguageTag -BaseLangId $BaseLangId -Klid $klid
            Remove-ProjectSubstitutes -BaseLangId $BaseLangId -AllowedKlids @($klid) -StaleKlids $staleKlids
        } else {
            Write-Warning "Could not derive a language profile for '$($Layout.id)' from LANGID $BaseLangId; not adding a modern user language profile."
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
    public const uint WM_INPUTLANGCHANGE        = 0x0051;
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
        [void][KbdActivate]::SendMessageTimeout(
            [KbdActivate]::HWND_BROADCAST,
            [KbdActivate]::WM_INPUTLANGCHANGE,
            [UIntPtr]::Zero, $hkl,
            [KbdActivate]::SMTO_ABORTIFHUNG, 2000,
            [ref]$result)
    } catch {
        Write-Warning "Live activation failed for ${klid}: $_. Sign out and back in if needed."
    }
}

Write-Host ""
Write-Host "==> Install complete: $($LayoutId -join ', ')"
Write-Host "    Win+Space should list installed layouts now."

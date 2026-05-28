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
$installAllPackaged = (-not $LayoutId -or $LayoutId.Count -eq 0)
if (-not $installAllPackaged) {
    $LayoutId = @($LayoutId | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

$manifestJson = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$manifest = @($manifestJson | ForEach-Object { $_ })
$layoutsById = @{}
foreach ($layout in $manifest) { $layoutsById[[string]$layout.id] = $layout }
if ($installAllPackaged) {
    $LayoutId = @($manifest | Where-Object { [bool]$_.packaged } | ForEach-Object { [string]$_.id } | Select-Object -Unique)
}
if (-not $LayoutId -or $LayoutId.Count -eq 0) { throw "No packaged layouts selected from $ManifestPath" }

$osArch = try {
    (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).OSArchitecture
} catch {
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
}
$arch = switch -Regex ($osArch) {
    'ARM\s*64|Arm64' {
        # Use an ARM64X forwarder so both ARM64-native and x64-compatible text
        # hosts can load the keyboard layout.
        'arm64x'
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

    if (-not (Test-Path -LiteralPath $SourceDll)) { throw "DLL not found: $SourceDll" }
    $name = [System.IO.Path]::GetFileName($OriginalDllName)
    if (-not $name -or -not $name.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid keyboard layout DLL name in manifest: $OriginalDllName"
    }
    return $name.ToLowerInvariant()
}

function Get-Arm64XSidecarNames {
    param([Parameter(Mandatory)][string]$DllName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($DllName)
    $armSide = if ($base.Length -le 7) { "${base}a" } else { $base.Substring(0, 6) + 'aa' }
    $x64Side = if ($base.Length -le 7) { "${base}x" } else { $base.Substring(0, 6) + 'xx' }
    return @("$armSide.dll", "$x64Side.dll")
}

function Get-LayoutHashHighWord {
    param([Parameter(Mandatory)][string]$SourceDll)

    $hash = (Get-FileHash -LiteralPath $SourceDll -Algorithm SHA256).Hash.ToLowerInvariant()
    $seed = [Convert]::ToInt32($hash.Substring(0, 3), 16)
    return 1 + ($seed % 0x0fff)
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
        [Parameter(Mandatory)][string]$ProjectLayoutId,
        [Parameter(Mandatory)][string[]]$LayoutFiles
    )

    Get-ChildItem $LayoutsKey | Where-Object {
        try {
            $props = Get-ItemProperty $_.PSPath
            $sameProjectLayout = $props.'Layout Product Code' -eq $ProductCode -and $props.'Keyremap Layout Id' -eq $ProjectLayoutId
            $sameLegacyProduct = $props.'Layout Product Code' -eq $ProductCode -and $props.'Layout Text' -eq $LayoutText
            $sameFile = $LayoutFiles -contains $props.'Layout File'
            $sameProjectLayout -or $sameLegacyProduct -or $sameFile
        } catch {
            $false
        }
    }
}

function Remove-PreloadKlids {
    param([string[]]$Klids)

    if (-not $Klids -or $Klids.Count -eq 0) { return }
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

function Add-PreloadKlid {
    param([Parameter(Mandatory)][string]$Klid)

    $preload = 'HKCU:\Keyboard Layout\Preload'
    if (-not (Test-Path $preload)) {
        New-Item -Path $preload -Force | Out-Null
    }

    foreach ($prop in (Get-Item $preload).Property) {
        $val = [string](Get-ItemProperty $preload -Name $prop).$prop
        if ($val.Equals($Klid, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "User preload already present: slot $prop -> $val"
            return
        }
    }

    $used = @{}
    foreach ($prop in (Get-Item $preload).Property) {
        $slot = 0
        if ([int]::TryParse($prop, [ref]$slot)) { $used[$slot] = $true }
    }
    $next = 1
    while ($used.ContainsKey($next)) { $next++ }
    New-ItemProperty -Path $preload -Name ([string]$next) -Value $Klid -PropertyType String -Force | Out-Null
    Write-Host "Added user preload entry: slot $next -> $Klid"
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
            $isKnownStale = $stale.ContainsKey($keyboard)
            if ($isKnownStale) { $remove += [string]$tip }
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

    $emptyProfiles = @()
    foreach ($profile in $list) {
        $remove = @()
        foreach ($tip in @($profile.InputMethodTips)) {
            $parts = ([string]$tip).Split(':')
            if ($parts.Count -eq 2 -and
                $parts[1].Equals($Klid, [System.StringComparison]::OrdinalIgnoreCase) -and
                $profile -ne $lang) {
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
    if ($changed) { Set-WinUserLanguageList $list -Force }
}

function Set-UserLanguageTipExclusive {
    param(
        [Parameter(Mandatory)][string]$LanguageTag,
        [Parameter(Mandatory)][string]$BaseLangId,
        [Parameter(Mandatory)][string]$Klid
    )

    $targetTip = ('{0}:{1}' -f $BaseLangId.ToUpperInvariant(), $Klid.ToUpperInvariant())
    $prefix = $BaseLangId.ToUpperInvariant() + ':'
    $list = Get-WinUserLanguageList
    $lang = $null
    foreach ($item in $list) {
        if ($item.LanguageTag -eq $LanguageTag) { $lang = $item; break }
    }
    if (-not $lang) {
        $newList = New-WinUserLanguageList $LanguageTag
        $lang = $newList[0]
        $list.Add($lang)
    }

    foreach ($item in $list) {
        foreach ($tip in @($item.InputMethodTips)) {
            $tipString = [string]$tip
            if ($tipString.ToUpperInvariant().StartsWith($prefix) -and $tipString -ne $targetTip) {
                [void]$item.InputMethodTips.Remove($tipString)
                Write-Host "Removed competing language input method: $tipString"
            }
        }
    }
    if (-not ($lang.InputMethodTips -contains $targetTip)) {
        [void]$lang.InputMethodTips.Add($targetTip)
        Write-Host "Added user language input method: $targetTip"
    }
    Set-WinUserLanguageList $list -Force
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
        $isProjectBaseRedirect = $propLower -eq "0000$($BaseLangId.ToLowerInvariant())" -and $allowed.ContainsKey($valueLower)
        if ($valueIsStale -or $isWrongBaseRedirect -or $isWrongGeneratedRedirect -or $isProjectBaseRedirect) {
            Remove-ItemProperty -Path $substitutes -Name $propString
            Write-Host "Removed stale keyboard substitute $propString -> $valueString"
        }
    }
}

function Set-ProjectSubstitute {
    param(
        [Parameter(Mandatory)][string]$BaseLangId,
        [Parameter(Mandatory)][string]$Klid
    )

    $substitutes = 'HKCU:\Keyboard Layout\Substitutes'
    if (-not (Test-Path $substitutes)) {
        New-Item -Path $substitutes -Force | Out-Null
    }
    $baseKlid = "0000$BaseLangId".ToLowerInvariant()
    $targetKlid = $Klid.ToLowerInvariant()
    Set-ItemProperty -Path $substitutes -Name $baseKlid -Value $targetKlid -Type String
    Write-Host "Set keyboard substitute $baseKlid -> $targetKlid"
}

function Remove-BaseLanguageSubstitute {
    param([Parameter(Mandatory)][string]$BaseLangId)

    $substitutes = 'HKCU:\Keyboard Layout\Substitutes'
    if (-not (Test-Path $substitutes)) { return }
    $baseKlid = "0000$BaseLangId".ToLowerInvariant()
    foreach ($prop in @((Get-Item $substitutes).Property)) {
        if ([string]$prop -eq $baseKlid) {
            $value = [string](Get-ItemProperty $substitutes -Name $prop).$prop
            Remove-ItemProperty -Path $substitutes -Name $prop
            Write-Host "Removed base-language substitute $prop -> $value"
        }
    }
}

function Set-CtfKeyboardSortOrder {
    param(
        [Parameter(Mandatory)][string]$VisibleKlid,
        [Parameter(Mandatory)][string]$HklName
    )

    $keyboardTipGuid = '{34745C63-B2F0-4784-8B67-5E12C8701A31}'
    $visibleKlidLower = $VisibleKlid.ToLowerInvariant()
    $path = "HKCU:\Software\Microsoft\CTF\SortOrder\AssemblyItem\0x$visibleKlidLower\$keyboardTipGuid\00000000"
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }

    Set-ItemProperty -Path $path -Name 'CLSID' -Value '{00000000-0000-0000-0000-000000000000}' -Type String
    Set-ItemProperty -Path $path -Name 'Profile' -Value '{00000000-0000-0000-0000-000000000000}' -Type String
    Set-ItemProperty -Path $path -Name 'KeyboardLayout' -Value ([Convert]::ToInt64($HklName, 16)) -Type DWord
    Write-Host "Set CTF keyboard sort-order for $visibleKlidLower -> HKL $HklName"
}

function Remove-CtfKeyboardSortOrder {
    param([Parameter(Mandatory)][string]$VisibleKlid)

    $path = "HKCU:\Software\Microsoft\CTF\SortOrder\AssemblyItem\0x$($VisibleKlid.ToLowerInvariant())"
    if (Test-Path $path) {
        Remove-Item -Path $path -Recurse -Force
        Write-Host "Removed stale CTF keyboard sort-order: $VisibleKlid"
    }
}

function Add-CtfLanguageSortOrder {
    param([Parameter(Mandatory)][string]$VisibleKlid)

    $path = 'HKCU:\Software\Microsoft\CTF\SortOrder\Language'
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }

    foreach ($prop in @((Get-Item $path).Property)) {
        $val = [string](Get-ItemProperty $path -Name $prop).$prop
        if ($val.Equals($VisibleKlid, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "CTF language sort-order already present: $prop -> $val"
            return
        }
    }

    $used = @{}
    foreach ($prop in (Get-Item $path).Property) {
        $slot = 0
        if ([int]::TryParse($prop, [ref]$slot)) { $used[$slot] = $true }
    }
    $next = 0
    while ($used.ContainsKey($next)) { $next++ }
    New-ItemProperty -Path $path -Name ('{0:d8}' -f $next) -Value $VisibleKlid -PropertyType String -Force | Out-Null
    Write-Host "Added CTF language sort-order: $('{0:d8}' -f $next) -> $VisibleKlid"
}

function Remove-CtfLanguageSortOrder {
    param([Parameter(Mandatory)][string]$VisibleKlid)

    $path = 'HKCU:\Software\Microsoft\CTF\SortOrder\Language'
    if (-not (Test-Path $path)) { return }
    foreach ($prop in @((Get-Item $path).Property)) {
        $val = [string](Get-ItemProperty $path -Name $prop).$prop
        if ($val.Equals($VisibleKlid, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-ItemProperty -Path $path -Name $prop
            Write-Host "Removed stale CTF language sort-order: $prop -> $val"
        }
    }
}

function Set-BaseLayoutOverride {
    param(
        [Parameter(Mandatory)][string]$BaseLangId,
        [Parameter(Mandatory)][string]$PayloadFile,
        [Parameter(Mandatory)][string]$LayoutText,
        [Parameter(Mandatory)][string]$ProjectLayoutId
    )

    $baseKlid = "0000$BaseLangId".ToLowerInvariant()
    $keyPath = Join-Path $LayoutsKey $baseKlid
    if (-not (Test-Path $keyPath)) {
        New-Item -Path $LayoutsKey -Name $baseKlid -Force | Out-Null
    }

    $props = Get-ItemProperty $keyPath
    foreach ($name in @('Layout File', 'Layout Text', 'Layout Display Name', 'Layout Id')) {
        $backupName = "Keyremap Original $name"
        if (-not (Get-ItemProperty $keyPath -Name $backupName -ErrorAction SilentlyContinue)) {
            $value = $props.$name
            if ($null -ne $value) {
                Set-ItemProperty -Path $keyPath -Name $backupName -Value ([string]$value) -Type String
            }
        }
    }

    Set-ItemProperty -Path $keyPath -Name 'Layout File' -Value $PayloadFile -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Text' -Value $LayoutText -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Display Name' -Value "@%SystemRoot%\system32\$PayloadFile,-1000" -Type ExpandString
    Remove-ItemProperty -Path $keyPath -Name 'Layout Id' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $keyPath -Name 'Layout Product Code' -Value $ProductCode -Type String
    Set-ItemProperty -Path $keyPath -Name 'Keyremap Layout Id' -Value $ProjectLayoutId -Type String
    Set-ItemProperty -Path $keyPath -Name 'Keyremap Overrides Base KLID' -Value '1' -Type String
    Write-Host "Overrode base KLID $baseKlid so Windows shell uses $LayoutText directly."
    return $baseKlid
}

# --- Pick unused KLID + Layout Id ---------------------------------------------
function Get-AvailableLayoutIds {
    param(
        [Parameter(Mandatory)][string]$BaseLangId,
        [int]$PreferredHighWord = -1,
        [int]$PreferredLayoutId = -1,
        [string[]]$ExcludeKlids = @()
    )

    $existing = Get-ChildItem $LayoutsKey
    $excluded = @{}
    foreach ($klid in $ExcludeKlids) {
        if ($klid) { $excluded[$klid.ToLowerInvariant()] = $true }
    }
    $existingKlids = $existing | ForEach-Object { $_.PSChildName }
    $existingLayoutIds = @{}
    $existingLayoutLowIds = @{}
    foreach ($k in $existing) {
        if ($excluded.ContainsKey($k.PSChildName.ToLowerInvariant())) { continue }
        try {
            $id = (Get-ItemProperty $k.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
            if ($id) {
                $layoutIdValue = [Convert]::ToInt32($id, 16)
                $existingLayoutIds[$id.ToLower()] = $true
                $existingLayoutLowIds[('{0:x3}' -f ($layoutIdValue -band 0xfff))] = $true
            }
        } catch { }
    }
    $klid = $null
    if ($PreferredHighWord -ge 0x0001 -and $PreferredHighWord -le 0x0fff) {
        $candidate = ('{0:x4}{1}' -f $PreferredHighWord, $BaseLangId)
        if ($existingKlids -notcontains $candidate) { $klid = $candidate }
    }
    for ($hi = 0x0001; $hi -le 0x0fff; $hi++) {
        if ($klid) { break }
        $candidate = ('{0:x4}{1}' -f $hi, $BaseLangId)
        if ($existingKlids -notcontains $candidate) { $klid = $candidate; break }
    }
    if (-not $klid) { throw "No free variant KLID available in range 0001..0fff for LANGID $BaseLangId" }

    $layoutId = $null
    if ($PreferredLayoutId -ge 0x00a0 -and $PreferredLayoutId -le 0xffff) {
        $candidate = ('{0:x4}' -f $PreferredLayoutId)
        $candidateLow = ('{0:x3}' -f ($PreferredLayoutId -band 0xfff))
        if (-not $existingLayoutIds.ContainsKey($candidate) -and -not $existingLayoutLowIds.ContainsKey($candidateLow)) { $layoutId = $candidate }
    }
    for ($id = 0x00a0; $id -le 0xffff; $id++) {
        if ($layoutId) { break }
        $candidate = ('{0:x4}' -f $id)
        $candidateLow = ('{0:x3}' -f ($id -band 0xfff))
        if (-not $existingLayoutIds.ContainsKey($candidate) -and -not $existingLayoutLowIds.ContainsKey($candidateLow)) { $layoutId = $candidate; break }
    }
    if (-not $layoutId) { throw "No free Layout Id available in range 00a0..ffff" }

    return @{ Klid = $klid; LayoutId = $layoutId }
}

function Get-HklNameForKlid {
    param([Parameter(Mandatory)][string]$Klid)

    $keyPath = Join-Path $LayoutsKey $Klid.ToLowerInvariant()
    $layoutIdHex = (Get-ItemProperty $keyPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
    if (-not $layoutIdHex) { return $null }
    $layoutIdValue = [Convert]::ToInt32($layoutIdHex, 16)
    $baseLangId = $Klid.Substring($Klid.Length - 4).ToUpperInvariant()
    return ('F{0:X3}{1}' -f ($layoutIdValue -band 0xfff), $baseLangId)
}

function Remove-StalePayloadFiles {
    param(
        [string[]]$PayloadFiles,
        [Parameter(Mandatory)][string]$KeepPayloadFile
    )

    if (-not $PayloadFiles -or $PayloadFiles.Count -eq 0) { return }
    foreach ($file in @($PayloadFiles | Where-Object { $_ } | Select-Object -Unique)) {
        if ($file.Equals($KeepPayloadFile, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $path = Join-Path $System32 $file
        if (-not (Test-Path $path)) { continue }
        try {
            Remove-Item -LiteralPath $path -Force
            Write-Host "Removed stale payload DLL: $path"
        } catch {
            Write-Warning "Could not remove stale payload DLL ${path}: $_"
        }
    }
}

function Install-OneLayout {
    param([Parameter(Mandatory)]$Layout)

    $ProjectLayoutId = [string]$Layout.id
    $LayoutFile = [string]$Layout.dllName
    $LayoutText = [string]$Layout.displayName
    $BaseLangId = [string]$Layout.baseLangId
    $LanguageTag = [string]$Layout.languageTag
    $OverrideBaseKlid = [bool]$Layout.overrideBaseKlid
    if (-not $LayoutFile -or -not $LayoutText -or -not $BaseLangId) {
        throw "Manifest entry '$($Layout.id)' is missing dllName/displayName/baseLangId"
    }
    if (-not $LanguageTag) { $LanguageTag = Resolve-LanguageTag -BaseLangId $BaseLangId }

    $runtimeLayoutFile = if ($arch -eq 'arm64x') {
        # Windows accepts the x64-compatible sidecar as a keyboard Layout File
        # in x64 text hosts. A pure ARM64X forwarder can be LoadLibrary'd, but
        # LoadKeyboardLayout rejects it on current Windows 11 ARM builds.
        (Get-Arm64XSidecarNames -DllName $LayoutFile)[1]
    } else {
        $LayoutFile
    }

    $sourceDll = if ($DllPath -and $LayoutId.Count -eq 1) {
        $DllPath
    } else {
        Join-Path $RepoRoot "build\$arch\$runtimeLayoutFile"
    }
    if (-not (Test-Path $sourceDll)) {
        throw "DLL not found for '$($Layout.id)' at $sourceDll. This layout is listed but not packaged for $arch yet."
    }

    $payloadFile = Get-LayoutPayloadName -SourceDll $sourceDll -OriginalDllName $runtimeLayoutFile
    $preferredHighWord = Get-LayoutHashHighWord -SourceDll $sourceDll
    $preferredLayoutId = Get-LayoutHashLayoutId -SourceDll $sourceDll
    $preferredLayoutIdHex = ('{0:x4}' -f $preferredLayoutId)
    $preferredKlid = ('{0:x4}{1}' -f $preferredHighWord, $BaseLangId)
    $knownLayoutFiles = @($LayoutFile, $payloadFile)
    if ($arch -eq 'arm64x') { $knownLayoutFiles += Get-Arm64XSidecarNames -DllName $LayoutFile }
    $existing = @(Get-InstalledLayoutEntries -LayoutText $LayoutText -ProjectLayoutId $ProjectLayoutId -LayoutFiles $knownLayoutFiles)
    $matchingPayload = @($existing | Where-Object {
        try { (Get-ItemProperty $_.PSPath).'Layout File' -eq $payloadFile } catch { $false }
    } | Select-Object -First 1)
    $matchingPreferredPayload = @($matchingPayload | Where-Object { $_.PSChildName -eq $preferredKlid } | Select-Object -First 1)
    $staleKlids = @()
    $staleHkls = @()
    $stalePayloadFiles = @()

    if ($existing -and -not $Force) {
        $entry = if ($matchingPayload) { $matchingPayload[0] } else { $existing[0] }
        Write-Host "$LayoutText already registered as KLID $($entry.PSChildName). Use -Force to overwrite."
        $klid = $entry.PSChildName
        $layoutIdHex = (Get-ItemProperty $entry.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
        if (-not $layoutIdHex) { $layoutIdHex = (Get-AvailableLayoutIds -BaseLangId $BaseLangId).LayoutId }
    } else {
        $refreshEntry = if ($matchingPreferredPayload) { $matchingPreferredPayload[0] } elseif ($matchingPayload) { $matchingPayload[0] } elseif ($existing) { $existing[0] } else { $null }
        if ($refreshEntry -and $Force) {
            $klid = $refreshEntry.PSChildName
            $currentLayoutIdHex = (Get-ItemProperty $refreshEntry.PSPath -Name 'Layout Id' -ErrorAction SilentlyContinue).'Layout Id'
            $ids = Get-AvailableLayoutIds -BaseLangId $BaseLangId -PreferredHighWord $preferredHighWord -PreferredLayoutId $preferredLayoutId -ExcludeKlids @($klid)
            $layoutIdHex = $ids.LayoutId
            if ($currentLayoutIdHex -and $currentLayoutIdHex.ToLowerInvariant() -ne $layoutIdHex) {
                $currentLayoutIdValue = [Convert]::ToInt32($currentLayoutIdHex, 16)
                $staleHkls += ('F{0:X3}{1}' -f ($currentLayoutIdValue -band 0xfff), $BaseLangId.ToUpperInvariant())
                Write-Host "Changing Layout Id for $klid from $currentLayoutIdHex to $layoutIdHex to avoid a Windows layout-name collision."
            }
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
    if ($arch -eq 'arm64x') {
        $forwarderSource = Join-Path $RepoRoot "build\arm64x\$LayoutFile"
        if (Test-Path $forwarderSource) {
            $forwarderDest = Join-Path $System32 $LayoutFile
            Write-Host "Copying $forwarderSource -> $forwarderDest"
            Copy-Item -Path $forwarderSource -Destination $forwarderDest -Force
        }
        foreach ($sidecar in (Get-Arm64XSidecarNames -DllName $LayoutFile)) {
            $sidecarSource = Join-Path $RepoRoot "build\arm64x\$sidecar"
            if (-not (Test-Path $sidecarSource)) { throw "ARM64X sidecar missing: $sidecarSource" }
            $sidecarDest = Join-Path $System32 $sidecar
            if ($sidecarDest.Equals($dest, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Write-Host "Copying $sidecarSource -> $sidecarDest"
            Copy-Item -Path $sidecarSource -Destination $sidecarDest -Force
        }
    }

    $staleEntries = @($existing | Where-Object { $_.PSChildName -ne $klid })
    if ($staleEntries.Count -gt 0) {
        $staleKlids = @($staleEntries | ForEach-Object { $_.PSChildName })
        $staleHkls = @($staleKlids | ForEach-Object { Get-HklNameForKlid -Klid $_ } | Where-Object { $_ })
        $stalePayloadFiles = @($staleEntries | ForEach-Object {
            try { (Get-ItemProperty $_.PSPath).'Layout File' } catch { $null }
        })
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
    Set-ItemProperty -Path $keyPath -Name 'Layout Display Name' -Value "@%SystemRoot%\system32\$payloadFile,-1000" -Type ExpandString
    Set-ItemProperty -Path $keyPath -Name 'Layout Id' -Value $layoutIdHex -Type String
    Set-ItemProperty -Path $keyPath -Name 'Layout Product Code' -Value $ProductCode -Type String
    Set-ItemProperty -Path $keyPath -Name 'Keyremap Layout Id' -Value $ProjectLayoutId -Type String
    Write-Host "Registered at $keyPath"

    $visibleKlid = if ($OverrideBaseKlid) {
        Set-BaseLayoutOverride -BaseLangId $BaseLangId -PayloadFile $payloadFile -LayoutText $LayoutText -ProjectLayoutId $ProjectLayoutId
    } else {
        $klid
    }

    if ($AddToCurrentUser) {
        Remove-PreloadKlids -Klids $staleKlids
        if ($OverrideBaseKlid) { Remove-PreloadKlids -Klids @($klid) }
        Remove-StaleUserLanguageTips -BaseLangId $BaseLangId -StaleKlids $staleKlids
        if ($OverrideBaseKlid) {
            Remove-ProjectSubstitutes -BaseLangId $BaseLangId -AllowedKlids @($klid) -StaleKlids $staleKlids
            Remove-BaseLanguageSubstitute -BaseLangId $BaseLangId
        }
        Add-PreloadKlid -Klid $visibleKlid
        $visibleHklName = if ($OverrideBaseKlid) { $visibleKlid } else { Get-HklNameForKlid -Klid $visibleKlid }
        if (-not $visibleHklName) { $visibleHklName = $visibleKlid }
        Remove-CtfKeyboardSortOrder -VisibleKlid $klid
        Remove-CtfLanguageSortOrder -VisibleKlid $klid
        Set-CtfKeyboardSortOrder -VisibleKlid $visibleKlid -HklName $visibleHklName
        Add-CtfLanguageSortOrder -VisibleKlid $visibleKlid
        if ($LanguageTag) {
            if ($OverrideBaseKlid) {
                Set-UserLanguageTipExclusive -LanguageTag $LanguageTag -BaseLangId $BaseLangId -Klid $visibleKlid
                Remove-ProjectSubstitutes -BaseLangId $BaseLangId -AllowedKlids @($klid) -StaleKlids $staleKlids
                Remove-BaseLanguageSubstitute -BaseLangId $BaseLangId
            } else {
                Add-UserLanguageTip -LanguageTag $LanguageTag -BaseLangId $BaseLangId -Klid $visibleKlid
            }
            Set-CtfKeyboardSortOrder -VisibleKlid $visibleKlid -HklName $visibleHklName
            Add-CtfLanguageSortOrder -VisibleKlid $visibleKlid
        } else {
            Write-Warning "Could not derive a language profile for '$($Layout.id)' from LANGID $BaseLangId; not adding a modern user language profile."
        }
    }

    Remove-StalePayloadFiles -PayloadFiles $stalePayloadFiles -KeepPayloadFile $payloadFile

    return [pscustomobject]@{
        Klid = $klid
        VisibleKlid = $visibleKlid
        StaleHkls = @($staleHkls)
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

    [DllImport("user32.dll")]
    public static extern int GetKeyboardLayoutList(int nBuff, IntPtr[] lpList);

    [DllImport("user32.dll")]
    public static extern bool UnloadKeyboardLayout(IntPtr hkl);

    public const uint KLF_ACTIVATE      = 0x00000001;
    public const uint KLF_SUBSTITUTE_OK = 0x00000002;
    public const uint KLF_REORDER       = 0x00000008;
    public const uint KLF_REPLACELANG   = 0x00000010;
    public const uint WM_INPUTLANGCHANGEREQUEST = 0x0050;
    public const uint WM_SETTINGCHANGE          = 0x001A;
    public const uint WM_INPUTLANGCHANGE        = 0x0051;
    public static readonly IntPtr HWND_BROADCAST = (IntPtr)0xFFFF;
    public const uint SMTO_ABORTIFHUNG = 0x0002;
}
'@ -ErrorAction SilentlyContinue

$installedLayouts = @()
foreach ($id in $LayoutId) {
    if (-not $layoutsById.ContainsKey($id)) { throw "Unknown layout id '$id' in manifest $ManifestPath" }
    $layout = $layoutsById[$id]
    if (-not [bool]$layout.packaged) { throw "Layout '$id' is not packaged yet." }
    $installedLayouts += Install-OneLayout -Layout $layout
}

foreach ($installedLayout in $installedLayouts) {
    $klid = if ($installedLayout.VisibleKlid) { [string]$installedLayout.VisibleKlid } else { [string]$installedLayout.Klid }
    try {
        $hkl = [KbdActivate]::LoadKeyboardLayout(
            $klid,
            [KbdActivate]::KLF_ACTIVATE -bor
                [KbdActivate]::KLF_SUBSTITUTE_OK -bor
                [KbdActivate]::KLF_REORDER -bor
                [KbdActivate]::KLF_REPLACELANG)
        if ($hkl -eq [IntPtr]::Zero) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Warning "LoadKeyboardLayout($klid) returned NULL (error $code). You may need to sign out."
        } else {
            Write-Host ("LoadKeyboardLayout OK for {0} (HKL=0x{1:X})" -f $klid, $hkl.ToInt64())
        }
        $staleHkls = @{}
        foreach ($staleHkl in @($installedLayout.StaleHkls)) {
            if ($staleHkl) { $staleHkls[[string]$staleHkl] = $true }
        }
        $layoutCount = [KbdActivate]::GetKeyboardLayoutList(0, $null)
        if ($layoutCount -gt 0 -and $staleHkls.Count -gt 0) {
            $loadedLayouts = New-Object IntPtr[] $layoutCount
            [void][KbdActivate]::GetKeyboardLayoutList($layoutCount, $loadedLayouts)
            foreach ($loadedHkl in $loadedLayouts) {
                $loadedHex = '{0:X8}' -f [uint32]($loadedHkl.ToInt64() -band 0xffffffffL)
                if ($staleHkls.ContainsKey($loadedHex)) {
                    if ([KbdActivate]::UnloadKeyboardLayout($loadedHkl)) {
                        Write-Host "Unloaded stale live keyboard layout HKL $loadedHex"
                    }
                }
            }
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

#Requires -Version 5.1
<#
.SYNOPSIS
  Generate the packaged layout manifest from the reviewed XKB/Windows catalog.

.DESCRIPTION
  The broad catalog says which XKB rows have a corresponding Windows language
  family. This script turns the rows Windows does not already cover into stable
  installable manifest entries. By default it packages the Dvorak-family gap
  first, because that is the proven cross-language problem this repo currently
  verifies end to end. Use -AllMissing to draft every missing candidate as
  packaged once the converter/build coverage is ready for that scale.
#>

[CmdletBinding()]
param(
    [switch]$AllMissing,

    [string]$FamilyPattern = 'dvorak',

    [string]$CandidatePath,

    [string]$WindowsPath,

    [string]$OutPath
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CandidatePath) { $CandidatePath = Join-Path $RepoRoot 'data\xkb-windows-candidates.json' }
if (-not $WindowsPath) { $WindowsPath = Join-Path $RepoRoot 'data\windows-keyboards.local.json' }
if (-not $OutPath) { $OutPath = Join-Path $RepoRoot 'data\layouts.json' }

function Normalize-Text {
    param([string]$Text)
    return (($Text.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Get-StableDllName {
    param([Parameter(Mandatory)][string]$Id)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Id)
        $hash = $sha1.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { '{0:x2}' -f $_ })
        return "kx$($hex.Substring(0, 6)).dll"
    } finally {
        $sha1.Dispose()
    }
}

function Get-DisplayName {
    param([Parameter(Mandatory)][string]$Description)
    $name = $Description -replace '\(([^)]*)\)', ' $1'
    $name = $name -replace ',', ''
    $name = $name -replace '\s+', ' '
    return $name.Trim()
}

function Resolve-LanguageTag {
    param([Parameter(Mandatory)][string]$LangId)
    try {
        return [Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($LangId, 16)).Name
    } catch {
        return $null
    }
}

function Get-MatchedWindowsText {
    param($Candidate)
    foreach ($reason in @($Candidate.match.reasons)) {
        if ([string]$reason -match "description overlaps Windows '([^']+)'") { return $matches[1] }
    }
    foreach ($reason in @($Candidate.match.reasons)) {
        if ([string]$reason -match "Windows '([^']+)'") { return $matches[1] }
    }
    return $null
}

function Get-Id {
    param([string]$Layout, [string]$Variant)
    $id = if ($Variant) { "$Layout-$Variant" } else { $Layout }
    return (($id.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}

$candidatesJson = Get-Content $CandidatePath -Raw | ConvertFrom-Json
$windowsJson = Get-Content $WindowsPath -Raw | ConvertFrom-Json
$candidates = @($candidatesJson | ForEach-Object { $_ })
$windowsRows = @($windowsJson | ForEach-Object { $_ })
$windowsByText = @{}
$windowsNormalized = @{}
foreach ($row in $windowsRows) {
    $text = [string]$row.layoutText
    if ($text -and -not $windowsByText.ContainsKey($text)) { $windowsByText[$text] = $row }
    $norm = Normalize-Text $text
    if ($norm -and -not $windowsNormalized.ContainsKey($norm)) { $windowsNormalized[$norm] = $row }
}

$knownBuiltInIds = @{
    'us-dvorak' = $true
    'us-dvorak-l' = $true
    'us-dvorak-r' = $true
    'tr-f' = $true
}

$preferredWindowsFamilyByLayout = @{
    'us' = 'US'
    'gb' = 'United Kingdom'
    'br' = 'Portuguese (Brazil ABNT)'
    'latam' = 'Latin American'
}

$preferredLangIdByLayout = @{
    'gb' = '0809'
    'latam' = '080a'
    'br' = '0416'
}

$layouts = New-Object System.Collections.Generic.List[object]
foreach ($candidate in $candidates) {
    if ([string]$candidate.match.status -ne 'candidate') { continue }
    $layout = [string]$candidate.xkb.layout
    $variant = [string]$candidate.xkb.variant
    $description = [string]$candidate.xkb.description
    $id = Get-Id -Layout $layout -Variant $variant
    $descriptionNorm = Normalize-Text $description
    $builtInExact = $windowsNormalized.ContainsKey($descriptionNorm) -or $knownBuiltInIds.ContainsKey($id)
    if ($builtInExact) { continue }
    if (-not $AllMissing) {
        $haystack = "$id $description".ToLowerInvariant()
        if (-not $haystack.Contains($FamilyPattern.ToLowerInvariant())) { continue }
    }

    $matchedText = if ($preferredWindowsFamilyByLayout.ContainsKey($layout)) {
        $preferredWindowsFamilyByLayout[$layout]
    } else {
        Get-MatchedWindowsText -Candidate $candidate
    }
    $matchedRow = if ($matchedText -and $windowsByText.ContainsKey($matchedText)) { $windowsByText[$matchedText] } else { $null }
    if ($preferredLangIdByLayout.ContainsKey($layout)) {
        $baseLangId = $preferredLangIdByLayout[$layout]
    } else {
        if (-not $matchedRow) { continue }
        $klid = [string]$matchedRow.klid
        if ($klid.Length -lt 4) { continue }
        $baseLangId = $klid.Substring($klid.Length - 4).ToLowerInvariant()
    }
    $languageTag = Resolve-LanguageTag -LangId $baseLangId
    $displayName = Get-DisplayName -Description $description
    $dllName = if ($id -eq 'is-dvorak') { 'kbdisdv.dll' } else { Get-StableDllName -Id $id }

    $layouts.Add([ordered]@{
        id = $id
        displayName = $displayName
        xkbLayout = $layout
        xkbVariant = $variant
        windowsFamily = if ($matchedRow) { [string]$matchedRow.layoutText } else { $matchedText }
        windowsAlreadyExists = $false
        packaged = $true
        baseLangId = $baseLangId
        languageTag = $languageTag
        dllName = $dllName
        overrideBaseKlid = ($id -eq 'is-dvorak')
        description = if ($variant) { "Linux xkeyboard-config $layout($variant)" } else { "Linux xkeyboard-config $layout" }
    })
}

$ordered = @($layouts | Sort-Object { $_.displayName }, { $_.id })
New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
$json = ($ordered | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
[IO.File]::WriteAllText($OutPath, $json + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutPath ($($ordered.Count) packaged layouts)"

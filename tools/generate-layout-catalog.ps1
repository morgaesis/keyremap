#Requires -Version 5.1
<#
.SYNOPSIS
  Generate a reviewable XKB-to-Windows keyboard candidate catalog.

.DESCRIPTION
  Parses xkeyboard-config rules\base.xml and the local Windows keyboard layout
  registry. It emits a Markdown diff and JSON data set showing XKB layouts and
  variants whose language/country family appears to exist in Windows.
#>

[CmdletBinding()]
param(
    [string]$XkbRoot = (Join-Path $env:TEMP 'xkeyboard-config-keyremap'),
    [string]$XkbGitUrl = 'https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config.git'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $XkbRoot)) {
    git clone --depth 1 --filter=blob:none --sparse $XkbGitUrl $XkbRoot | Out-Host
    git -C $XkbRoot sparse-checkout set rules symbols | Out-Host
} else {
    git -C $XkbRoot fetch --depth 1 origin HEAD | Out-Host
    git -C $XkbRoot checkout FETCH_HEAD | Out-Host
    git -C $XkbRoot sparse-checkout set rules symbols | Out-Host
}

$baseXml = Join-Path $XkbRoot 'rules\base.xml'
if (-not (Test-Path $baseXml)) { throw "Missing $baseXml" }

$windowsRows = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts' | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath
    [pscustomobject]@{
        klid = $_.PSChildName
        layoutText = [string]$p.'Layout Text'
        layoutFile = [string]$p.'Layout File'
        custom = $_.PSChildName -match '^a[0-9a-f]{7}$'
    }
} | Where-Object { -not $_.custom }

$countryAliases = @{
    'ara' = @('arabic')
    'latam' = @('latin american')
    'apl' = @('united states')
    'epo' = @('esperanto')
    'brai' = @('braille')
    'cn' = @('chinese')
    'jp' = @('japanese')
    'kr' = @('korean')
    'gb' = @('united kingdom')
    'us' = @('united states')
}
$stopWords = @(
    'keyboard', 'layout', 'legacy', 'standard', 'with', 'for', 'and',
    'the', 'alt', 'alternate', 'international', 'intl', 'only',
    'extended', 'enhanced'
)

function Normalize-Words([string]$s) {
    (($s.ToLowerInvariant() -replace '[^a-z0-9]+', ' ') -split '\s+' | Where-Object { $_.Length -gt 1 }) |
        Select-Object -Unique
}

function Get-XkbLanguages($node) {
    $langs = @()
    if ($node.configItem.languageList -and $node.configItem.languageList.iso639Id) {
        $langs += @($node.configItem.languageList.iso639Id | ForEach-Object { [string]$_ })
    }
    return @($langs | Where-Object { $_ } | Select-Object -Unique)
}

function Test-WindowsMatch([string]$layout, [string]$description, [string[]]$langs) {
    $reasons = New-Object System.Collections.Generic.List[string]
    $needReview = $false

    $aliases = @()
    if ($layout.Length -gt 2) { $aliases += $layout }
    if ($countryAliases.ContainsKey($layout)) { $aliases += $countryAliases[$layout] }
    foreach ($alias in $aliases) {
        if (($windowsRows.layoutText -contains $alias) -or (($windowsRows.layoutText -join "`n").ToLowerInvariant().Contains($alias.ToLowerInvariant()))) {
            $reasons.Add("windows text contains '$alias'")
            break
        }
    }

    $descWords = @(Normalize-Words $description | Where-Object { $_ -notin $stopWords -and $_.Length -gt 2 })
    $firstWord = $descWords | Select-Object -First 1
    foreach ($row in $windowsRows) {
        $winWords = @(Normalize-Words $row.layoutText | Where-Object { $_ -notin $stopWords -and $_.Length -gt 2 })
        $overlap = @($descWords | Where-Object { $winWords -contains $_ })
        if ($overlap.Count -ge 2 -or ($firstWord -and $winWords -contains $firstWord)) {
            $reasons.Add("description overlaps Windows '$($row.layoutText)'")
            break
        }
    }

    foreach ($lang in $langs) {
        if ($description.ToLowerInvariant().Contains($lang.ToLowerInvariant())) {
            $needReview = $true
        }
    }

    [pscustomobject]@{
        matched = $reasons.Count -gt 0
        reasons = @($reasons)
        needsReview = $needReview
    }
}

[xml]$xml = Get-Content $baseXml -Raw
$items = New-Object System.Collections.Generic.List[object]

foreach ($layoutNode in $xml.xkbConfigRegistry.layoutList.layout) {
    $layout = [string]$layoutNode.configItem.name
    $layoutDescription = [string]$layoutNode.configItem.description
    $layoutLangs = @(Get-XkbLanguages $layoutNode)

    $defaultMatch = Test-WindowsMatch -layout $layout -description $layoutDescription -langs $layoutLangs
    $items.Add([pscustomobject]@{
        xkb = [ordered]@{
            layout = $layout
            variant = ''
            description = $layoutDescription
            languages = $layoutLangs
        }
        match = [ordered]@{
            status = if ($defaultMatch.matched) { 'candidate' } else { 'excluded' }
            reasons = $defaultMatch.reasons
        }
    })

    foreach ($variantNode in @($layoutNode.variantList.variant)) {
        if (-not $variantNode) { continue }
        $variant = [string]$variantNode.configItem.name
        $variantDescription = [string]$variantNode.configItem.description
        $variantLangs = @(Get-XkbLanguages $variantNode)
        if ($variantLangs.Count -eq 0) { $variantLangs = $layoutLangs }
        $m = Test-WindowsMatch -layout $layout -description $variantDescription -langs $variantLangs
        $items.Add([pscustomobject]@{
            xkb = [ordered]@{
                layout = $layout
                variant = $variant
                description = $variantDescription
                languages = $variantLangs
            }
            match = [ordered]@{
                status = if ($m.matched) { 'candidate' } else { 'excluded' }
                reasons = $m.reasons
            }
        })
    }
}

$dataDir = Join-Path $RepoRoot 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$windowsOut = Join-Path $dataDir 'windows-keyboards.local.json'
$candidateOut = Join-Path $dataDir 'xkb-windows-candidates.json'
$markdownOut = Join-Path $RepoRoot 'docs\layout-candidates.md'

$windowsRows | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $windowsOut
$items | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $candidateOut

$candidates = @($items | Where-Object { $_.match.status -eq 'candidate' })
$excluded = @($items | Where-Object { $_.match.status -eq 'excluded' })
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# XKB Windows Candidate Diff')
$lines.Add('')
$lines.Add("Generated from ``$baseXml`` and local Windows keyboard registry.")
$lines.Add('')
$lines.Add("- Windows registry keyboard rows: $($windowsRows.Count)")
$lines.Add("- XKB rows inspected: $($items.Count)")
$lines.Add("- Candidate rows: $($candidates.Count)")
$lines.Add("- Excluded rows: $($excluded.Count)")
$lines.Add('')
$lines.Add('## Candidates')
$lines.Add('')
$lines.Add('| XKB | Description | Reasons |')
$lines.Add('|---|---|---|')
foreach ($item in $candidates | Sort-Object { $_.xkb.layout }, { $_.xkb.variant }) {
    $name = if ($item.xkb.variant) { "$($item.xkb.layout)($($item.xkb.variant))" } else { $item.xkb.layout }
    $lines.Add("| ``$name`` | $($item.xkb.description) | $($item.match.reasons -join '; ') |")
}
$lines.Add('')
$lines.Add('## Excluded')
$lines.Add('')
$lines.Add('| XKB | Description |')
$lines.Add('|---|---|')
foreach ($item in $excluded | Sort-Object { $_.xkb.layout }, { $_.xkb.variant }) {
    $name = if ($item.xkb.variant) { "$($item.xkb.layout)($($item.xkb.variant))" } else { $item.xkb.layout }
    $lines.Add("| ``$name`` | $($item.xkb.description) |")
}
$lines | Set-Content -Encoding UTF8 $markdownOut

Write-Host "Wrote $windowsOut"
Write-Host "Wrote $candidateOut"
Write-Host "Wrote $markdownOut"

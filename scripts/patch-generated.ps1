#Requires -Version 5.1
<#
.SYNOPSIS
  Patch kbdutool output with printable character tables from the KLC source.

.DESCRIPTION
  On this toolchain kbdutool accepts the KLC and emits scan-code/dead-key
  tables, but omits the main printable VK_TO_WCHARS table. This script derives
  that table from src\kbdisdv.klc and injects it into generated\kbdisdv.c.
#>

[CmdletBinding()]
param(
    [string]$KlcPath,
    [string]$CPath
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $KlcPath) { $KlcPath = Join-Path $RepoRoot 'src\kbdisdv.klc' }
if (-not $CPath) { $CPath = Join-Path $RepoRoot 'generated\kbdisdv.c' }

if (-not (Test-Path $KlcPath)) { throw "KLC not found: $KlcPath" }
if (-not (Test-Path $CPath)) { throw "C source not found: $CPath" }

$klcLines = Get-Content $KlcPath -Encoding UTF8
$vkRows = New-Object System.Collections.Generic.List[object]
$inLayout = $false

function Convert-KlcCell {
    param([string]$Cell)
    $cell = $Cell.Trim()
    if ($cell -eq '-1') { return @{ Main = 'WCH_NONE'; Dead = $null } }
    $dead = $cell.EndsWith('@')
    if ($dead) { $cell = $cell.Substring(0, $cell.Length - 1) }

    $expr = $null
    if ($cell.Length -eq 1 -and [int][char]$cell -lt 128 -and $cell -match '[A-Za-z0-9]') {
        $expr = "0x{0:x4}" -f [int][char]$cell
    } elseif ($cell -match '^[0-9a-fA-F]{4,6}$') {
        $expr = "0x$($cell.ToLowerInvariant())"
    } else {
        $expr = "0x{0:x4}" -f [int][char]$cell[0]
    }

    if ($dead) {
        return @{ Main = 'WCH_DEAD'; Dead = $expr }
    }
    return @{ Main = $expr; Dead = $null }
}

foreach ($line in $klcLines) {
    if ($line -match '^LAYOUT\b') { $inLayout = $true; continue }
    if ($inLayout -and $line -match '^(DEADKEY|KEYNAME|DESCRIPTIONS|LANGUAGENAMES|ENDKBD)\b') { break }
    if (-not $inLayout) { continue }
    if ($line -match '^\s*(;|$)') { continue }

    $withoutComment = ($line -split ';', 2)[0].Trim()
    if (-not $withoutComment) { continue }
    $parts = $withoutComment -split '\s+'
    if ($parts.Count -lt 8) { continue }

    $vk = $parts[1]
    if ($vk -in @('TAB', 'BACK', 'RETURN', 'ESCAPE', 'CANCEL')) { continue }
    if ($vk -match '^OEM_|^[A-Z0-9]+$|^SPACE$') {
        $cells = @(
            Convert-KlcCell $parts[3]
            Convert-KlcCell $parts[4]
            Convert-KlcCell $parts[5]
            Convert-KlcCell $parts[6]
            Convert-KlcCell $parts[7]
        )
        $hasChar = @($cells | Where-Object { $_.Main -ne 'WCH_NONE' }).Count -gt 0
        if (-not $hasChar) { continue }
        $attr = if ($parts[2] -eq '1') { 'CAPLOK' } else { '0' }
        $vkExpr = if ($vk -match '^[A-Z0-9]$') { "'$vk'" } else { "VK_$vk" }
        $vkRows.Add([pscustomobject]@{ Vk = $vkExpr; Attr = $attr; Cells = $cells })
    }
}

if ($vkRows.Count -eq 0) { throw "No printable KLC rows parsed from $KlcPath" }

$tableLines = New-Object System.Collections.Generic.List[string]
$tableLines.Add("static ALLOC_SECTION_LDATA VK_TO_WCHARS5 aVkToWch5[] = {")
$tableLines.Add("//                      |         |  Shift  |  Ctrl   |  AltGr  |S+AltGr |")
$tableLines.Add("//                      |=========|=========|=========|=========|=========|")
foreach ($row in $vkRows) {
    $main = @($row.Cells | ForEach-Object { $_.Main })
    $tableLines.Add(("  {{{0,-13},{1,-7},{2,-9},{3,-9},{4,-9},{5,-9},{6,-9}}}," -f $row.Vk, $row.Attr, $main[0], $main[1], $main[2], $main[3], $main[4]))
    $dead = @($row.Cells | ForEach-Object { if ($_.Dead) { $_.Dead } else { 'WCH_NONE' } })
    if (@($row.Cells | Where-Object { $_.Dead }).Count -gt 0) {
        $tableLines.Add(("  {{0xff         ,0      ,{0,-9},{1,-9},{2,-9},{3,-9},{4,-9}}}," -f $dead[0], $dead[1], $dead[2], $dead[3], $dead[4]))
    }
}
$tableLines.Add("  {0            ,0      ,0        ,0        ,0        ,0        ,0        }")
$tableLines.Add("};")
$tableLines.Add("")
$tableText = ($tableLines -join "`r`n")

$c = Get-Content $CPath -Raw
$insertBefore = 'static ALLOC_SECTION_LDATA VK_TO_WCHARS2 aVkToWch2\[\] = \{'
if ($c -notmatch $insertBefore) { throw "Could not locate aVkToWch2 insertion point in $CPath" }
$c = [regex]::Replace($c, $insertBefore, ($tableText + "`r`n" + 'static ALLOC_SECTION_LDATA VK_TO_WCHARS2 aVkToWch2[] = {'), 1)

$tableEntry = '    {  (PVK_TO_WCHARS1)aVkToWch5, 5, sizeof(aVkToWch5[0]) },'
$c = $c -replace '(static ALLOC_SECTION_LDATA VK_TO_WCHAR_TABLE aVkToWcharTable\[\] = \{\s*)', "`$1$tableEntry`r`n"

Set-Content -Path $CPath -Value $c -Encoding ASCII -NoNewline
Write-Host "Injected $($vkRows.Count) printable VK rows into $CPath"

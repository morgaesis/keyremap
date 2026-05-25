#Requires -Version 5.1
<#
.SYNOPSIS
  Generate C sources for the Icelandic Dvorak keyboard layout.

.DESCRIPTION
  Uses MSKLC's command-line tool, kbdutool.exe, to turn src\kbdisdv.klc into
  generated\kbdisdv.{c,h,def,rc}. The generated directory is not committed.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

$KlcSrc   = Join-Path $RepoRoot 'src\kbdisdv.klc'
$GenRoot  = Join-Path $RepoRoot 'generated'
$KbdUtool = "${env:ProgramFiles(x86)}\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe"

if (-not (Test-Path $KbdUtool)) {
    throw "kbdutool.exe not found at $KbdUtool. Install MSKLC 1.4 or run scripts/install-kbdutool.ps1."
}
if (-not (Test-Path $KlcSrc)) {
    throw "Source KLC missing: $KlcSrc"
}

New-Item -ItemType Directory -Force -Path $GenRoot | Out-Null
Get-ChildItem $GenRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force

# kbdutool -u requires UTF-16 LE + BOM + CRLF.
$klcText = Get-Content $KlcSrc -Raw -Encoding UTF8
$generatedKlc = Join-Path $GenRoot 'kbdisdv.klc'
$utf16 = [System.Text.Encoding]::Unicode
$bytes = $utf16.GetPreamble() + $utf16.GetBytes(($klcText -replace "`r?`n", "`r`n"))
[System.IO.File]::WriteAllBytes($generatedKlc, $bytes)

Push-Location $GenRoot
try {
    & $KbdUtool -u -s 'kbdisdv.klc' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "kbdutool failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

Get-ChildItem $GenRoot -Include '*.C', '*.H', '*.DEF', '*.RC' -File | ForEach-Object {
    $new = $_.BaseName + $_.Extension.ToLower()
    Rename-Item -LiteralPath $_.FullName -NewName $new -Force
}

Write-Host "Generated sources under: $GenRoot"

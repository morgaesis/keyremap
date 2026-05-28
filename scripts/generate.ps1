#Requires -Version 5.1
<#
.SYNOPSIS
  Generate C sources for a keyboard layout.

.DESCRIPTION
  Uses MSKLC's command-line tool, kbdutool.exe, to turn a KLC file into
  generated\<base>.{c,h,def,rc}. The generated directory is not committed.
#>

[CmdletBinding()]
param(
    [string]$KlcSrc,

    [string]$BaseName,

    [string]$GenRoot
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $KlcSrc) { $KlcSrc = Join-Path $RepoRoot 'src\kbdisdv.klc' }
if (-not $BaseName) { $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($KlcSrc) }
if (-not $GenRoot) { $GenRoot = Join-Path $RepoRoot 'generated' }
$KbdUtoolCandidates = @(
    (Join-Path $RepoRoot '.tools\msklc\bin\i386\kbdutool.exe'),
    "${env:ProgramFiles(x86)}\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe"
)
$KbdUtool = $KbdUtoolCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $KbdUtool) {
    throw "kbdutool.exe not found. Run scripts/install-kbdutool.ps1."
}
if (-not (Test-Path $KlcSrc)) {
    throw "Source KLC missing: $KlcSrc"
}

New-Item -ItemType Directory -Force -Path $GenRoot | Out-Null
Get-ChildItem $GenRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force

# kbdutool -u requires UTF-16 LE + BOM + CRLF.
$klcText = Get-Content $KlcSrc -Raw -Encoding UTF8
$generatedKlc = Join-Path $GenRoot "$BaseName.klc"
$utf16 = [System.Text.Encoding]::Unicode
$bytes = $utf16.GetPreamble() + $utf16.GetBytes(($klcText -replace "`r?`n", "`r`n"))
[System.IO.File]::WriteAllBytes($generatedKlc, $bytes)

Push-Location $GenRoot
try {
    & $KbdUtool -u -s "$BaseName.klc" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "kbdutool failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

Get-ChildItem $GenRoot -Include '*.C', '*.H', '*.DEF', '*.RC' -File | ForEach-Object {
    $new = $_.BaseName + $_.Extension.ToLower()
    Rename-Item -LiteralPath $_.FullName -NewName $new -Force
}

$cPath = Join-Path $GenRoot "$BaseName.c"
if (Test-Path $cPath) {
    & (Join-Path $PSScriptRoot 'patch-generated.ps1') -KlcPath $KlcSrc -CPath $cPath -HPath (Join-Path $GenRoot "$BaseName.h")
}

Write-Host "Generated sources under: $GenRoot"

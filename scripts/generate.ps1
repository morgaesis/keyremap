#Requires -Version 5.1
<#
.SYNOPSIS
  Regenerate generated\kbdisdv.{c,h,def,rc} from src\kbdisdv.klc.

.DESCRIPTION
  Uses kbdutool.exe from Microsoft Keyboard Layout Creator 1.4 to convert
  the KLC source into the C/H/DEF/RC files that the build pipeline consumes.

  This step is only needed when modifying src\kbdisdv.klc. The generated
  files are committed to the repo so CI does not need MSKLC installed.

  Prerequisites:
    - Microsoft Keyboard Layout Creator 1.4 installed (kbdutool.exe)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$KlcSrc = Join-Path $RepoRoot 'src\kbdisdv.klc'
$OutDir = Join-Path $RepoRoot 'generated'
$KbdUtool = "${env:ProgramFiles(x86)}\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe"

if (-not (Test-Path $KbdUtool)) {
    throw "kbdutool.exe not found at $KbdUtool. Install MSKLC 1.4 from https://www.microsoft.com/en-us/download/details.aspx?id=102134"
}
if (-not (Test-Path $KlcSrc)) {
    throw "Source KLC missing: $KlcSrc"
}

# kbdutool writes outputs next to its input and does not accept --output.
# Run it in a scratch dir, then move the outputs into generated\.
$Scratch = Join-Path $env:TEMP "keyremap-gen-$(Get-Random)"
New-Item -ItemType Directory -Path $Scratch | Out-Null
try {
    Copy-Item $KlcSrc $Scratch
    Push-Location $Scratch
    try {
        & $KbdUtool -u -s (Split-Path -Leaf $KlcSrc)
        if ($LASTEXITCODE -ne 0) { throw "kbdutool failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Get-ChildItem $Scratch -Include *.C, *.H, *.DEF, *.RC -File | ForEach-Object {
        $dest = Join-Path $OutDir ($_.BaseName + $_.Extension.ToLower())
        Copy-Item $_.FullName $dest -Force
        Write-Host "Generated: $dest"
    }
} finally {
    Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==> Regeneration complete. Review the diff under generated\ and commit."

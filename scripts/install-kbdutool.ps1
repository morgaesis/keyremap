#Requires -Version 5.1
<#
.SYNOPSIS
  Install MSKLC 1.4 so kbdutool.exe is available.

.DESCRIPTION
  This downloads Microsoft's MSKLC installer and runs it silently. The repo
  uses only kbdutool.exe from MSKLC; it does not use the MSKLC GUI or setup
  package output for keyboard installation.
#>

[CmdletBinding()]
param(
    [string]$MsklcUrl = 'https://download.microsoft.com/download/6/f/5/6f5ce43a-e892-4fd1-b9a6-1a0cbb64e6e2/MSKLC.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $RepoRoot '.tools\msklc'
$repoTool = Join-Path $toolRoot 'bin\i386\kbdutool.exe'
if (Test-Path $repoTool) {
    Write-Host "kbdutool already present: $repoTool"
    return
}

$installed = 'C:\Program Files (x86)\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe'
if (Test-Path $installed) {
    Write-Host "kbdutool already present: $installed"
    return
}

$tmp = Join-Path $env:TEMP "msklc-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $exe = Join-Path $tmp 'MSKLC.exe'
    Invoke-WebRequest -Uri $MsklcUrl -OutFile $exe -UseBasicParsing

    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $sevenZip) { $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue }
    if (-not $sevenZip) { throw "7-Zip is required to extract MSKLC.exe without running the GUI installer." }

    $sfxOut = Join-Path $tmp 'sfx'
    New-Item -ItemType Directory -Force -Path $sfxOut | Out-Null
    & $sevenZip.Source x $exe "-o$sfxOut" -y | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not extract MSKLC.exe with 7-Zip (exit $LASTEXITCODE)" }

    $msi = Get-ChildItem $sfxOut -Recurse -Filter 'MSKLC.msi' | Select-Object -First 1
    if (-not $msi) { throw "MSKLC.msi was not found inside MSKLC.exe" }

    $adminOut = Join-Path $tmp 'admin'
    New-Item -ItemType Directory -Force -Path $adminOut | Out-Null
    $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/a', $msi.FullName, '/qn', "TARGETDIR=$adminOut") -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        throw "MSKLC administrative extraction failed with exit $($p.ExitCode)"
    }
    $extractedTool = Join-Path $adminOut 'bin\i386\kbdutool.exe'
    if (-not (Test-Path $extractedTool)) {
        throw "kbdutool.exe missing after extraction; expected $extractedTool"
    }

    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    Copy-Item -Path (Join-Path $adminOut '*') -Destination $toolRoot -Recurse -Force
    Write-Host "Extracted kbdutool to: $repoTool"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

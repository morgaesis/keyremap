#Requires -Version 5.1
<#
.SYNOPSIS
  Build the visible Windows installer.
#>

[CmdletBinding()]
param(
    [string]$InnoCompiler
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $InnoCompiler) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    $InnoCompiler = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $InnoCompiler) {
    throw "ISCC.exe not found. Install Inno Setup 6 with: winget install --id JRSoftware.InnoSetup -e"
}

foreach ($arch in @('x86', 'x64', 'arm64')) {
    $dll = Join-Path $RepoRoot "build\$arch\kbdisdv.dll"
    if (-not (Test-Path $dll)) {
        & (Join-Path $PSScriptRoot 'build.ps1') -Arch $arch
        if ($LASTEXITCODE -ne 0) { throw "build.ps1 failed for $arch" }
    }
}

& (Join-Path $PSScriptRoot 'export-installer-layouts.ps1')

& $InnoCompiler (Join-Path $RepoRoot 'installer\keyremap.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compiler failed with exit $LASTEXITCODE" }

Write-Output (Join-Path $RepoRoot 'installer\Output\keyremap-setup.exe')

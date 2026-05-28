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

$manifestPath = Join-Path $RepoRoot 'data\layouts.json'
$manifestJson = Get-Content $manifestPath -Raw | ConvertFrom-Json
$layouts = @($manifestJson | ForEach-Object { $_ } | Where-Object { [bool]$_.packaged })
if ($layouts.Count -eq 0) { throw "No packaged layouts found in $manifestPath" }

foreach ($archDir in @('x86', 'x64', 'arm64', 'arm64x')) {
    $dir = Join-Path $RepoRoot "build\$archDir"
    if (Test-Path $dir) {
        Get-ChildItem (Join-Path $dir '*') -File -Include *.dll,*.lib,*.exp,*.obj,*.res,*.def,*.rc -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

foreach ($layout in $layouts) {
    $id = [string]$layout.id
    $dllName = [string]$layout.dllName
    $baseName = [IO.Path]::GetFileNameWithoutExtension($dllName)
    $klcSrc = if ($id -eq 'is-dvorak') {
        Join-Path $RepoRoot 'src\kbdisdv.klc'
    } else {
        & (Join-Path $PSScriptRoot 'generate-xkb-klc.ps1') -LayoutId $id -ManifestPath $manifestPath | Select-Object -Last 1
    }
    $genRoot = Join-Path $RepoRoot "generated\$baseName"
    & (Join-Path $PSScriptRoot 'generate.ps1') -KlcSrc $klcSrc -BaseName $baseName -GenRoot $genRoot | Out-Host

    foreach ($arch in @('x86', 'x64', 'arm64')) {
        $dll = Join-Path $RepoRoot "build\$arch\$dllName"
        if (-not (Test-Path $dll)) {
            & (Join-Path $PSScriptRoot 'build.ps1') -Arch $arch -BaseName $baseName -KlcSrc $klcSrc -SrcDir $genRoot -DllName $dllName
            if ($LASTEXITCODE -ne 0) { throw "build.ps1 failed for $arch/$id" }
        }
    }
    & (Join-Path $PSScriptRoot 'build-arm64x-forwarder.ps1') -BaseName $baseName -DllName $dllName -LayoutName ([string]$layout.displayName) -KlcSrc $klcSrc | Out-Host
}

& (Join-Path $PSScriptRoot 'export-installer-layouts.ps1')

& $InnoCompiler (Join-Path $RepoRoot 'installer\keyremap.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compiler failed with exit $LASTEXITCODE" }

Write-Output (Join-Path $RepoRoot 'installer\Output\keyremap-setup.exe')

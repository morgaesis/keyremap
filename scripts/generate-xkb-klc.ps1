#Requires -Version 5.1
<#
.SYNOPSIS
  Generate a KLC source file from a packaged manifest entry.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LayoutId,

    [string]$ManifestPath,

    [string]$XkbRoot = (Join-Path $env:TEMP 'xkeyboard-config-keyremap'),

    [string]$KeysymDefPath,

    [string]$ComposePath,

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot 'data\layouts.json' }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'src\generated' }

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$manifestJson = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$layout = @($manifestJson | ForEach-Object { $_ } | Where-Object { [string]$_.id -eq $LayoutId }) | Select-Object -First 1
if (-not $layout) { throw "Layout '$LayoutId' not found in $ManifestPath" }

$symbolsDir = Join-Path $XkbRoot 'symbols'
if (-not (Test-Path $symbolsDir)) {
    throw "XKB symbols directory not found: $symbolsDir. Run tools/generate-layout-catalog.ps1 first."
}

if (-not $KeysymDefPath) {
    $candidates = @(
        '\\wsl.localhost\Ubuntu-24.04\usr\include\X11\keysymdef.h',
        'C:\msys64\mingw64\include\X11\keysymdef.h'
    )
    $KeysymDefPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $ComposePath) {
    $candidates = @(
        '\\wsl.localhost\Ubuntu-24.04\usr\share\X11\locale\en_US.UTF-8\Compose'
    )
    $ComposePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $KeysymDefPath) { throw "keysymdef.h not found. Install WSL X11 headers or MSYS2 libx11 headers." }
if (-not $ComposePath) { throw "X11 Compose file not found. Install WSL X11 locale data." }

$baseName = [IO.Path]::GetFileNameWithoutExtension([string]$layout.dllName)
$outPath = Join-Path $OutDir "$baseName.klc"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$variant = [string]$layout.xkbVariant
if (-not $variant) { $variant = 'basic' }

python (Join-Path $RepoRoot 'tools\xkb2klc\xkb2klc.py') `
    --symbols-dir $symbolsDir `
    --layout ([string]$layout.xkbLayout) `
    --variant $variant `
    --output $outPath `
    --keysymdef $KeysymDefPath `
    --compose $ComposePath `
    --metadata-json $ManifestPath
if ($LASTEXITCODE -ne 0) { throw "xkb2klc failed for $LayoutId" }

Write-Output $outPath

#Requires -Version 5.1
<#
.SYNOPSIS
  Build every packaged layout in the manifest for one native architecture.
#>

[CmdletBinding()]
param(
    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$Arch = 'x64',

    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot 'data\layouts.json' }

$manifestJson = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$layouts = @($manifestJson | ForEach-Object { $_ } | Where-Object { [bool]$_.packaged })
if ($layouts.Count -eq 0) { throw "No packaged layouts found in $ManifestPath" }

foreach ($layout in $layouts) {
    $id = [string]$layout.id
    $dllName = [string]$layout.dllName
    $baseName = [IO.Path]::GetFileNameWithoutExtension($dllName)
    Write-Host "==> Building $id ($dllName) for $Arch"
    $klcSrc = if ($id -eq 'is-dvorak') {
        Join-Path $RepoRoot 'src\kbdisdv.klc'
    } else {
        & (Join-Path $PSScriptRoot 'generate-xkb-klc.ps1') -LayoutId $id -ManifestPath $ManifestPath | Select-Object -Last 1
    }
    $genRoot = Join-Path $RepoRoot "generated\$baseName"
    & (Join-Path $PSScriptRoot 'generate.ps1') -KlcSrc $klcSrc -BaseName $baseName -GenRoot $genRoot | Out-Host
    & (Join-Path $PSScriptRoot 'build.ps1') -Arch $Arch -BaseName $baseName -KlcSrc $klcSrc -SrcDir $genRoot -DllName $dllName | Out-Host
}

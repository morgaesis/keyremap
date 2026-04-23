#Requires -Version 5.1
<#
.SYNOPSIS
  Compile a keyboard layout DLL variant for a target architecture.

.DESCRIPTION
  Takes the generated C/H/DEF/RC sources for a specified variant
  (see scripts/variants.ps1) and compiles them into a native kbd*.dll
  for the requested architecture via MSVC.

.PARAMETER Arch
  x86, x64, or arm64. Default: arm64.

.PARAMETER Variant
  default, caps-altgr, caps-esc, caps-ctrl. Default: default.

.PARAMETER OutDir
  Output directory. Defaults to build\<arch>\.
#>

[CmdletBinding()]
param(
    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$Arch = 'arm64',

    [string]$Variant = 'default',

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'variants.ps1')
$spec = Get-VariantSpec -Name $Variant

$SrcDir = Join-Path $RepoRoot "generated\$Variant"
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "build\$Arch" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path (Join-Path $SrcDir ($spec.BaseName + '.c')))) {
    Write-Host "generated\$Variant not populated — running generate.ps1 -Variant $Variant"
    & (Join-Path $PSScriptRoot 'generate.ps1') -Variant $Variant
    if ($LASTEXITCODE -ne 0) { throw "generate.ps1 failed" }
}

# --- Locate MSVC via vswhere ----------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found. Install Visual Studio 2022 Build Tools." }
$vsInstall = & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
if (-not $vsInstall) { throw "No VS install with MSVC C++ tools found." }
$vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found under $vsInstall." }

# --- Locate kbd.h --------------------------------------------------------------
$kbdH = $null
$candidates = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Include\*\um\kbd.h",
    "$env:ProgramFiles\Windows Kits\10\Include\*\um\kbd.h",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Include\*\km\kbd.h",
    "$env:ProgramFiles\Windows Kits\10\Include\*\km\kbd.h",
    "${env:ProgramFiles(x86)}\Microsoft Keyboard Layout Creator 1.4\inc\kbd.h"
)
foreach ($glob in $candidates) {
    $found = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { $kbdH = $found.DirectoryName; break }
}
if (-not $kbdH) {
    throw "kbd.h not found. Install the Windows 10/11 SDK via Visual Studio Installer, or MSKLC 1.4."
}
Write-Host "Using kbd.h from: $kbdH"

$vsArch = @{ 'x86' = 'x86'; 'x64' = 'amd64'; 'arm64' = 'arm64' }[$Arch]

$base = $spec.BaseName
$cSrc = Join-Path $SrcDir "$base.c"
$rcSrc = Join-Path $SrcDir "$base.rc"
$defSrc = Join-Path $SrcDir "$base.def"
$outDll = Join-Path $OutDir $spec.DllName
$resFile = Join-Path $OutDir "$base.res"
$objFile = Join-Path $OutDir "$base.obj"

foreach ($path in @($cSrc, $rcSrc, $defSrc)) {
    if (-not (Test-Path $path)) { throw "Missing source: $path." }
}

$buildCmd = @"
@echo on
call "$vsDevCmd" -arch=$vsArch -host_arch=amd64 -no_logo || exit /b 1

rc.exe /nologo /fo "$resFile" "$rcSrc" || exit /b 2

cl.exe /nologo /c /O2 /W3 /GS- /DWIN32 /D_WINDLL /D_USRDLL /DKBD_TYPE=4 ^
    /I"$kbdH" /I"$SrcDir" ^
    /Fo"$objFile" "$cSrc" || exit /b 3

link.exe /nologo /DLL /NOENTRY /NODEFAULTLIB /SUBSYSTEM:NATIVE ^
    /DEF:"$defSrc" /MACHINE:$($Arch.ToUpper()) ^
    /MERGE:.rdata=.data /MERGE:.edata=.data /IGNORE:4254 ^
    /OUT:"$outDll" "$objFile" "$resFile" || exit /b 4
"@

$bat = Join-Path $OutDir "_build-$base.bat"
$buildCmd | Set-Content -Encoding ASCII -Path $bat

Write-Host "Building $($spec.DllName) ($Arch, variant $Variant)..."
cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

if (-not (Test-Path $outDll)) { throw "Build finished but $outDll is missing." }
$size = (Get-Item $outDll).Length
Write-Host "Built: $outDll ($size bytes)"

# Verify via PE parsing
& (Join-Path $RepoRoot 'tests\verify-dll.ps1') -DllPath $outDll -ExpectedArch $Arch

Write-Output $outDll

#Requires -Version 5.1
<#
.SYNOPSIS
  Compile the Icelandic Dvorak keyboard layout DLL.

.DESCRIPTION
  Compiles generated\kbdisdv.c into kbdisdv.dll for the requested target
  architecture using the MSVC toolchain. Produces a keyboard-layout-format
  DLL suitable for copying into C:\Windows\System32 and registering as a
  native Windows keyboard layout.

  Requires:
    - Visual Studio 2022 Build Tools or full VS, with "Desktop C++" and
      "MSVC v143 ARM64/ARM64EC build tools" components.
    - Windows Driver Kit (WDK) 10 — provides kbd.h. Install via:
        choco install windowsdriverkit10.1 -y
      or through the Visual Studio Installer "Windows Driver Kit" component.

.PARAMETER Arch
  Target architecture. One of: x86, x64, arm64. Default: arm64.

.PARAMETER OutDir
  Directory for build output. Defaults to build\$Arch\.

.EXAMPLE
  .\scripts\build.ps1 -Arch arm64
  .\scripts\build.ps1 -Arch x64 -OutDir build-release\x64
#>

[CmdletBinding()]
param(
    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$Arch = 'arm64',

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir = Join-Path $RepoRoot 'generated'
if (-not $OutDir) {
    $OutDir = Join-Path $RepoRoot "build\$Arch"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- Locate MSVC via vswhere ----------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2022 Build Tools."
}
$vsInstall = & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
if (-not $vsInstall) { throw "No VS install with MSVC C++ tools found." }
$vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found under $vsInstall." }

# --- Locate kbd.h (shipped with recent Windows 10/11 SDKs under um\) -----------
# Order of preference:
#   1. Windows 10/11 SDK um\ directory (default on VS 2022 runners)
#   2. Windows 10/11 WDK km\ directory (installed via VS WDK component)
#   3. MSKLC 1.4 inc\ (dev machine fallback)
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
    throw "kbd.h not found. Install the Windows 10/11 SDK via Visual Studio Installer, or the WDK, or MSKLC 1.4."
}
Write-Host "Using kbd.h from: $kbdH"

# --- Map arch to VsDevCmd target arch ------------------------------------------
$vsArch = @{ 'x86' = 'x86'; 'x64' = 'amd64'; 'arm64' = 'arm64' }[$Arch]

# Call VsDevCmd to set up the environment for the target arch, then compile in
# that child shell. All cl/rc/link state lives in env vars inside cmd.exe.
$cSrc = Join-Path $SrcDir 'kbdisdv.c'
$rcSrc = Join-Path $SrcDir 'kbdisdv.rc'
$defSrc = Join-Path $SrcDir 'kbdisdv.def'
$outDll = Join-Path $OutDir 'kbdisdv.dll'
$resFile = Join-Path $OutDir 'kbdisdv.res'
$objFile = Join-Path $OutDir 'kbdisdv.obj'

foreach ($path in @($cSrc, $rcSrc, $defSrc)) {
    if (-not (Test-Path $path)) {
        throw "Missing source: $path. Regenerate via scripts\generate.ps1."
    }
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

$bat = Join-Path $OutDir '_build.bat'
$buildCmd | Set-Content -Encoding ASCII -Path $bat

Write-Host "Building kbdisdv.dll ($Arch)..."
cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

if (-not (Test-Path $outDll)) { throw "Build finished but $outDll is missing." }
$size = (Get-Item $outDll).Length
Write-Host "Built: $outDll ($size bytes)"

# --- Post-build sanity: KbdLayerDescriptor must be exported --------------------
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if (-not $dumpbin) {
    # dumpbin is in the MSVC bin dir — add it via a fresh VsDevCmd invocation
    $testBat = Join-Path $OutDir '_dump.bat'
    @"
@echo off
call "$vsDevCmd" -arch=$vsArch -host_arch=amd64 -no_logo >NUL 2>&1
dumpbin.exe /exports "$outDll"
"@ | Set-Content -Encoding ASCII -Path $testBat
    $exports = cmd.exe /c "`"$testBat`""
} else {
    $exports = & dumpbin.exe /exports $outDll
}

if ($exports -notmatch 'KbdLayerDescriptor') {
    throw "DLL is missing KbdLayerDescriptor export. Linker step failed silently."
}
Write-Host "OK: KbdLayerDescriptor is exported."

Write-Output $outDll

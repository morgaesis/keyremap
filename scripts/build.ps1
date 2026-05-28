#Requires -Version 5.1
<#
.SYNOPSIS
  Compile a keyboard layout DLL for a target architecture.

.DESCRIPTION
  Takes generated\<base>.{c,h,def,rc} and compiles it into a native
  keyboard layout DLL via MSVC.

.PARAMETER Arch
  x86, x64, or arm64. Default: arm64.

.PARAMETER OutDir
  Output directory. Defaults to build\<arch>\.
#>

[CmdletBinding()]
param(
    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$Arch = 'arm64',

    [string]$BaseName = 'kbdisdv',

    [string]$KlcSrc,

    [string]$SrcDir,

    [string]$DllName,

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $SrcDir) { $SrcDir = Join-Path $RepoRoot 'generated' }
if (-not $DllName) { $DllName = "$BaseName.dll" }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "build\$Arch" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path (Join-Path $SrcDir "$BaseName.c"))) {
    Write-Host "generated not populated; running generate.ps1"
    $generateArgs = @{
        BaseName = $BaseName
        GenRoot = $SrcDir
    }
    if ($KlcSrc) { $generateArgs.KlcSrc = $KlcSrc }
    & (Join-Path $PSScriptRoot 'generate.ps1') @generateArgs
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
$machineName = @{ 'x86' = 'x86'; 'x64' = 'x64'; 'arm64' = 'ARM64' }[$Arch]
$hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }

$base = $BaseName
$cSrc = Join-Path $SrcDir "$base.c"
$rcSrc = Join-Path $SrcDir "$base.rc"
$defSrc = Join-Path $SrcDir "$base.def"
$outDll = Join-Path $OutDir $DllName
$resFile = Join-Path $OutDir "$base.res"
$objFile = Join-Path $OutDir "$base.obj"
$patchedRcSrc = Join-Path $OutDir "$base.patched.rc"

foreach ($path in @($cSrc, $rcSrc, $defSrc)) {
    if (-not (Test-Path $path)) { throw "Missing source: $path." }
}

$layoutName = 'Icelandic Dvorak'
$klcPath = if ($KlcSrc) { $KlcSrc } else { Join-Path $RepoRoot "src\$base.klc" }
if (Test-Path $klcPath) {
    $klcText = Get-Content -Path $klcPath -Raw -Encoding UTF8
    if ($klcText -match '(?m)^KBD\s+\S+\s+"([^"]+)"') { $layoutName = $matches[1] }
}

$rcText = Get-Content -Path $rcSrc -Raw -Encoding Unicode
function Test-RcStringInLanguage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$PrimaryLanguage,
        [Parameter(Mandatory)][int]$SubLanguage,
        [Parameter(Mandatory)][int]$StringId
    )

    $pattern = '(?ms)STRINGTABLE\s+\S+\s+LANGUAGE\s+' +
        [regex]::Escape([string]$PrimaryLanguage) + '\s*,\s*' +
        [regex]::Escape([string]$SubLanguage) + '\s+BEGIN(?<body>.*?)END'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        if ($match.Groups['body'].Value -match "(?m)^\s*$StringId\s+`"") { return $true }
    }
    return $false
}

if (-not (Test-RcStringInLanguage -Text $rcText -PrimaryLanguage 9 -SubLanguage 1 -StringId 1000)) {
    $escapedLayoutName = $layoutName.Replace('"', '""')
    $rcText += @"

STRINGTABLE DISCARDABLE
LANGUAGE 9, 1
BEGIN
    1000    "$escapedLayoutName"
END

"@
}
Set-Content -Path $patchedRcSrc -Value $rcText -Encoding Unicode

$buildCmd = @"
@echo on
call "$vsDevCmd" -arch=$vsArch -host_arch=$hostArch -no_logo || exit /b 1

cl.exe /Bv 2>&1 | findstr /C:"for $machineName" >nul || (
    echo ERROR: VsDevCmd did not select a $machineName compiler.
    echo Install "MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools" for arm64 builds.
    exit /b 10
)

rc.exe /nologo /fo "$resFile" "$patchedRcSrc" || exit /b 2

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

Write-Host "Building $DllName ($Arch)..."
cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

if (-not (Test-Path $outDll)) { throw "Build finished but $outDll is missing." }
$size = (Get-Item $outDll).Length
Write-Host "Built: $outDll ($size bytes)"

# Verify via PE parsing
& (Join-Path $RepoRoot 'tests\verify-dll.ps1') -DllPath $outDll -ExpectedArch $Arch

if ($Arch -eq 'arm64') {
    Write-Warning "Plain ARM64 keyboard DLLs do not load in x64-compatible text hosts on Windows ARM. Package x64 for Windows ARM until a true merged ARM64X keyboard DLL is implemented."
}

Write-Output $outDll

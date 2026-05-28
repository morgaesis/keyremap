#Requires -Version 5.1
<#
.SYNOPSIS
  Build an ARM64X keyboard-layout forwarder for Windows on ARM.

.DESCRIPTION
  Windows on ARM has both native ARM64 text hosts and x64-compatible text
  hosts. Keyboard layout DLLs are loaded into those hosts, so a single x64 or
  ARM64 DLL is not enough. This builds a pure ARM64X forwarder named
  <base>.dll that forwards KbdLayerDescriptor to sidecar DLLs:

    <base>a.dll  ARM64 native layout
    <base>x.dll  x64 layout
#>

[CmdletBinding()]
param(
    [string]$BaseName = 'kbdisdv',

    [string]$DllName,

    [string]$LayoutName,

    [string]$KlcSrc,

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\arm64x' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not $DllName) { $DllName = "$BaseName.dll" }
$x64Dll = Join-Path $RepoRoot "build\x64\$DllName"
$arm64Dll = Join-Path $RepoRoot "build\arm64\$DllName"
if (-not (Test-Path $x64Dll)) { & (Join-Path $PSScriptRoot 'build.ps1') -Arch x64 -BaseName $BaseName -DllName $DllName -KlcSrc $KlcSrc }
if (-not (Test-Path $arm64Dll)) { & (Join-Path $PSScriptRoot 'build.ps1') -Arch arm64 -BaseName $BaseName -DllName $DllName -KlcSrc $KlcSrc }

$base = [System.IO.Path]::GetFileNameWithoutExtension($DllName)
$armSide = if ($base.Length -le 7) { "${base}a" } else { $base.Substring(0, 6) + 'aa' }
$x64Side = if ($base.Length -le 7) { "${base}x" } else { $base.Substring(0, 6) + 'xx' }
Copy-Item $arm64Dll (Join-Path $OutDir "$armSide.dll") -Force
Copy-Item $x64Dll (Join-Path $OutDir "$x64Side.dll") -Force

Set-Content -Path (Join-Path $OutDir "$armSide.def") -Encoding ASCII -Value @"
LIBRARY $armSide
EXPORTS
    KbdLayerDescriptor=$armSide.KbdLayerDescriptor @1
"@
Set-Content -Path (Join-Path $OutDir "$x64Side.def") -Encoding ASCII -Value @"
LIBRARY $x64Side
EXPORTS
    KbdLayerDescriptor=$x64Side.KbdLayerDescriptor @1
"@

if (-not $LayoutName) { $LayoutName = 'Icelandic Dvorak' }
$klcPath = if ($KlcSrc) { $KlcSrc } else { Join-Path $RepoRoot "src\$BaseName.klc" }
if (-not $LayoutName -and (Test-Path $klcPath)) {
    $klcText = Get-Content -Path $klcPath -Raw -Encoding UTF8
    if ($klcText -match '(?m)^KBD\s+\S+\s+"([^"]+)"') { $LayoutName = $matches[1] }
}
$escapedLayoutName = $LayoutName.Replace('"', '""')
Set-Content -Path (Join-Path $OutDir "$base.rc") -Encoding Unicode -Value @"
#include "winver.h"
1 VERSIONINFO
 FILEVERSION 1,0,0,0
 PRODUCTVERSION 1,0,0,0
 FILEOS 0x40004L
 FILETYPE VFT_DLL
 FILESUBTYPE VFT2_DRV_KEYBOARD
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "FileDescription", "$escapedLayoutName Keyboard Layout\0"
      VALUE "OriginalFilename", "$base.dll\0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 1200
  END
END
STRINGTABLE DISCARDABLE
LANGUAGE 9, 1
BEGIN
  1000 "$escapedLayoutName"
END
STRINGTABLE DISCARDABLE
LANGUAGE 15, 1
BEGIN
  1000 "$escapedLayoutName"
END
"@

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found. Install Visual Studio 2022 Build Tools." }
$vsInstall = & $vswhere -latest -products '*' -property installationPath
if (-not $vsInstall) { throw "No Visual Studio installation found." }
$vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'
$hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }

$cmd = @"
@echo on
call "$vsDevCmd" -arch=arm64 -host_arch=$hostArch -no_logo || exit /b 1
cd /d "$OutDir" || exit /b 2
type nul > empty.cpp || exit /b 3
cl /nologo /c /Foempty_arm64.obj empty.cpp || exit /b 4
cl /nologo /c /arm64EC /Foempty_x64.obj empty.cpp || exit /b 5
link /lib /machine:x64 /def:$x64Side.def /out:$x64Side.lib || exit /b 6
link /lib /machine:arm64 /def:$armSide.def /out:$armSide.lib || exit /b 7
rc /nologo /fo $base.res $base.rc || exit /b 8
link /dll /noentry /subsystem:native /machine:arm64x /defArm64Native:$armSide.def /def:$x64Side.def empty_arm64.obj empty_x64.obj $armSide.lib $x64Side.lib $base.res /out:$base.dll || exit /b 9
"@

$bat = Join-Path $OutDir "_build-$base-arm64x.bat"
Set-Content -Path $bat -Encoding ASCII -Value $cmd
cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "ARM64X forwarder build failed with exit code $LASTEXITCODE" }

Write-Output (Join-Path $OutDir "$base.dll")

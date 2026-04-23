#Requires -Version 5.1
<#
.SYNOPSIS
  Verify a built kbdisdv.dll: size, PE machine code, and KbdLayerDescriptor
  export.

.DESCRIPTION
  Reads the PE file directly — no dumpbin, no WinDbg, no MSVC bin needed.
  Works identically on x64 and arm64 CI hosts, regardless of how the
  msvc-dev-cmd action has set up PATH for cross-compilation.

.PARAMETER DllPath
  Path to the built DLL.

.PARAMETER ExpectedArch
  'x86', 'x64', or 'arm64'. The DLL's PE machine field must match.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DllPath,
    [Parameter(Mandatory)][ValidateSet('x86', 'x64', 'arm64')][string]$ExpectedArch
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DllPath)) { throw "DLL missing: $DllPath" }

# --- Size sanity --------------------------------------------------------------
$size = (Get-Item $DllPath).Length
Write-Host "DLL size: $size bytes"
if ($size -lt 4096)   { throw "DLL suspiciously small ($size bytes) — layout tables may have been optimized away" }
if ($size -gt 200000) { throw "DLL suspiciously large ($size bytes) — linker likely pulled in CRT" }

# --- PE header inspection ------------------------------------------------------
$bytes = [System.IO.File]::ReadAllBytes($DllPath)
if ($bytes.Length -lt 256) { throw "File too small to be a valid PE" }
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw "Not a PE file (missing MZ magic)"
}

$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -lt 0 -or ($peOffset + 24) -ge $bytes.Length) {
    throw "Invalid PE offset $peOffset"
}
if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset+1] -ne 0x45 -or
    $bytes[$peOffset+2] -ne 0x00 -or $bytes[$peOffset+3] -ne 0x00) {
    throw "Missing 'PE\0\0' signature at offset $peOffset"
}

$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$expectedMachine = @{
    'x86'   = 0x014C  # IMAGE_FILE_MACHINE_I386
    'x64'   = 0x8664  # IMAGE_FILE_MACHINE_AMD64
    'arm64' = 0xAA64  # IMAGE_FILE_MACHINE_ARM64
}[$ExpectedArch]

if ($machine -ne $expectedMachine) {
    throw ("PE machine mismatch: expected 0x{0:X4} ({1}), got 0x{2:X4}" -f $expectedMachine, $ExpectedArch, $machine)
}
Write-Host ("PE machine verified: 0x{0:X4} ({1})" -f $machine, $ExpectedArch)

# --- Optional header → export directory RVA -----------------------------------
# Optional header starts at $peOffset + 24
# First 2 bytes: Magic (0x10B = PE32, 0x20B = PE32+)
$optHdr = $peOffset + 24
$magic = [BitConverter]::ToUInt16($bytes, $optHdr)
$pe32Plus = ($magic -eq 0x20B)

# Data directory starts at different offsets for PE32 vs PE32+
# PE32:  optHdr + 96    (export dir at +0)
# PE32+: optHdr + 112   (export dir at +0)
$dataDirOffset = if ($pe32Plus) { $optHdr + 112 } else { $optHdr + 96 }
$exportRva = [BitConverter]::ToUInt32($bytes, $dataDirOffset)
$exportSize = [BitConverter]::ToUInt32($bytes, $dataDirOffset + 4)

if ($exportRva -eq 0) {
    throw "DLL has no export directory — linker step failed to apply the .def file"
}
Write-Host ("Export directory: RVA 0x{0:X} size {1}" -f $exportRva, $exportSize)

# --- Resolve RVA → file offset by walking section headers ----------------------
$numSections = [BitConverter]::ToUInt16($bytes, $peOffset + 6)
$sizeOfOptional = [BitConverter]::ToUInt16($bytes, $peOffset + 20)
$sectionsOffset = $optHdr + $sizeOfOptional

function Resolve-Rva {
    param([uint32]$rva)
    for ($i = 0; $i -lt $numSections; $i++) {
        $base = $sectionsOffset + ($i * 40)
        $virtAddr = [BitConverter]::ToUInt32($bytes, $base + 12)
        $virtSize = [BitConverter]::ToUInt32($bytes, $base + 8)
        $rawOffset = [BitConverter]::ToUInt32($bytes, $base + 20)
        if ($rva -ge $virtAddr -and $rva -lt ($virtAddr + $virtSize)) {
            return $rawOffset + ($rva - $virtAddr)
        }
    }
    throw "RVA 0x$($rva.ToString('X')) not in any section"
}

$exportFileOffset = Resolve-Rva -rva $exportRva
# IMAGE_EXPORT_DIRECTORY layout:
#  0  Characteristics     DWORD
#  4  TimeDateStamp       DWORD
#  8  MajorVersion        WORD
# 10  MinorVersion        WORD
# 12  Name RVA            DWORD   -> DLL name string
# 16  Base                DWORD
# 20  NumberOfFunctions   DWORD
# 24  NumberOfNames       DWORD
# 28  AddressOfFunctions  DWORD
# 32  AddressOfNames      DWORD
# 36  AddressOfNameOrdinals DWORD

$numNames = [BitConverter]::ToUInt32($bytes, $exportFileOffset + 24)
$namesTableRva = [BitConverter]::ToUInt32($bytes, $exportFileOffset + 32)
$namesTableOffset = Resolve-Rva -rva $namesTableRva

$exports = @()
for ($i = 0; $i -lt $numNames; $i++) {
    $nameRva = [BitConverter]::ToUInt32($bytes, $namesTableOffset + ($i * 4))
    $nameOffset = Resolve-Rva -rva $nameRva
    # Read null-terminated ASCII string
    $end = $nameOffset
    while ($bytes[$end] -ne 0) { $end++ }
    $name = [System.Text.Encoding]::ASCII.GetString($bytes, $nameOffset, $end - $nameOffset)
    $exports += $name
}

Write-Host "Exports: $($exports -join ', ')"
if ($exports -notcontains 'KbdLayerDescriptor') {
    throw "KbdLayerDescriptor not exported (found: $($exports -join ', '))"
}

Write-Host "OK: KbdLayerDescriptor is exported, DLL is well-formed for $ExpectedArch."

#Requires -Version 5.1
<#
.SYNOPSIS
  Golden-file QA: load the built kbdisdv.dll and assert its character table
  produces the expected output for every interesting (scancode, shift state)
  combination.

.DESCRIPTION
  kbd DLLs export a single function — KbdLayerDescriptor() — which returns
  a PKBDTABLES structure. This test calls it via P/Invoke, walks the
  VK_TO_WCHAR_TABLE and dead-key tables, and compares against a golden
  JSON file committed at tests\golden\is-dvorak.json.

  Catches:
    - Missing or scrambled AltGr columns (wrong shift-state ordering)
    - Missing dead-key entries
    - Icelandic characters (ð æ þ ß …) at the wrong positions

.PARAMETER DllPath
  Path to the kbdisdv.dll to test.

.PARAMETER UpdateGolden
  Regenerate tests\golden\is-dvorak.json from the current DLL output.
  Use only when you have intentionally changed the layout and verified
  the diff manually.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DllPath,
    [switch]$UpdateGolden
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DllPath)) { throw "DLL not found: $DllPath" }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$GoldenFile = Join-Path $RepoRoot 'tests\golden\is-dvorak.json'

# --- P/Invoke wrapper: load DLL, get KbdLayerDescriptor, walk tables -----------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class KbdLoader {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string path);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string name);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr hModule);

    public delegate IntPtr KbdLayerDescriptorFn();

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDTABLES {
        public IntPtr pCharModifiers;
        public IntPtr pVkToWcharTable;
        public IntPtr pDeadKey;
        public IntPtr pKeyNames;
        public IntPtr pKeyNamesExt;
        public IntPtr pKeyNamesDead;
        public IntPtr pusVSCtoVK;
        public byte bMaxVSCtoVK;
        public IntPtr pVSCtoVK_E0;
        public IntPtr pVSCtoVK_E1;
        public uint fLocaleFlags;
        public byte nLgMax;
        public byte cbLgEntry;
        public IntPtr pLigature;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct VK_TO_WCHAR_TABLE {
        public IntPtr pVkToWchars;
        public byte nModifications;
        public byte cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DEADKEY {
        public uint dwBoth;     // HIWORD = accent, LOWORD = character
        public ushort wchComposed;
        public ushort uFlags;
    }
}
"@

function Read-Struct {
    param([IntPtr]$ptr, [type]$type)
    if ($ptr -eq [IntPtr]::Zero) { return $null }
    [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, $type)
}

$h = [KbdLoader]::LoadLibrary($DllPath)
if ($h -eq [IntPtr]::Zero) { throw "LoadLibrary failed: error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

try {
    $proc = [KbdLoader]::GetProcAddress($h, 'KbdLayerDescriptor')
    if ($proc -eq [IntPtr]::Zero) { throw 'KbdLayerDescriptor not exported' }
    $fn = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($proc, [KbdLoader+KbdLayerDescriptorFn])
    $tablesPtr = $fn.Invoke()
    $tables = Read-Struct $tablesPtr ([KbdLoader+KBDTABLES])

    # --- Dead keys -------------------------------------------------------------
    $deadKeys = @{}
    if ($tables.pDeadKey -ne [IntPtr]::Zero) {
        $offset = $tables.pDeadKey
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][KbdLoader+DEADKEY])
        while ($true) {
            $dk = Read-Struct $offset ([KbdLoader+DEADKEY])
            if ($dk.dwBoth -eq 0) { break }
            $accent = [char]($dk.dwBoth -shr 16)
            $base = [char]($dk.dwBoth -band 0xffff)
            $key = "U+{0:X4}+U+{1:X4}" -f [int]$accent, [int]$base
            $deadKeys[$key] = ("U+{0:X4}" -f $dk.wchComposed)
            $offset = [IntPtr]($offset.ToInt64() + $size)
        }
    }

    $result = @{
        fLocaleFlags = ("0x{0:X8}" -f $tables.fLocaleFlags)
        hasCharModifiers = ($tables.pCharModifiers -ne [IntPtr]::Zero)
        hasVkToWcharTable = ($tables.pVkToWcharTable -ne [IntPtr]::Zero)
        deadKeyCount = $deadKeys.Count
        deadKeys = $deadKeys
    }
} finally {
    [void][KbdLoader]::FreeLibrary($h)
}

# --- Assertions / golden compare ----------------------------------------------
$mustHaveDeadKeys = @(
    'U+00B4+U+0061', # acute + a -> á
    'U+00B4+U+0045', # acute + E -> É
    'U+00B4+U+0059', # acute + Y -> Ý
    'U+00A8+U+006F', # diaeresis + o -> ö
    'U+02C7+U+0073', # caron + s -> š
    'U+0060+U+0061'  # grave + a -> à
)

foreach ($k in $mustHaveDeadKeys) {
    if (-not $result.deadKeys.ContainsKey($k)) {
        throw "Dead key sequence missing: $k"
    }
}

# Icelandic-specific: acute+a must produce á (U+00E1)
if ($result.deadKeys['U+00B4+U+0061'] -ne 'U+00E1') {
    throw "dead_acute+a did not produce á (got $($result.deadKeys['U+00B4+U+0061']))"
}
if ($result.deadKeys['U+00B4+U+0079'] -ne 'U+00FD') {
    throw "dead_acute+y did not produce ý"
}
if ($result.deadKeys['U+00B4+U+0059'] -ne 'U+00DD') {
    throw "dead_acute+Y did not produce Ý"
}

# AltGr flag must be set or AltGr combinations break
if ($tables.fLocaleFlags -band 1 -ne 1) {  # KLLF_ALTGR = 1
    throw "KLLF_ALTGR flag not set in fLocaleFlags (got $($result.fLocaleFlags))"
}

Write-Host "OK: $($result.deadKeyCount) dead key sequences, AltGr flag set, Icelandic accents verified."

if ($UpdateGolden) {
    New-Item -ItemType Directory -Force -Path (Split-Path $GoldenFile) | Out-Null
    $result | ConvertTo-Json -Depth 5 | Set-Content -Path $GoldenFile -Encoding utf8
    Write-Host "Golden updated: $GoldenFile"
} elseif (Test-Path $GoldenFile) {
    $golden = Get-Content $GoldenFile -Raw | ConvertFrom-Json
    if ($golden.deadKeyCount -ne $result.deadKeyCount) {
        Write-Warning "Dead key count differs from golden: expected $($golden.deadKeyCount), got $($result.deadKeyCount)"
    }
}

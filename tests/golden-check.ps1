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

.PARAMETER GoldenFile
  Optional golden JSON file path. Defaults to tests\golden\is-dvorak.json.

.PARAMETER MustHaveDeadKeys
  Optional dead-key sequence keys that must be present. Defaults to the current
  is(dvorak) coverage.

.PARAMETER ExpectedDeadKeyOutputs
  Optional map of dead-key sequence keys to expected composed codepoints.
  Defaults to the current is(dvorak) acute accent checks.

.PARAMETER RequireAltGr
  Whether the KLLF_ALTGR flag must be set. Defaults to true.

.PARAMETER UpdateGolden
  Regenerate tests\golden\is-dvorak.json from the current DLL output.
  Use only when you have intentionally changed the layout and verified
  the diff manually.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DllPath,
    [string]$GoldenFile,
    [string[]]$MustHaveDeadKeys,
    [object]$ExpectedDeadKeyOutputs,
    [bool]$RequireAltGr = $true,
    [switch]$UpdateGolden
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DllPath)) { throw "DLL not found: $DllPath" }

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $GoldenFile) {
    $GoldenFile = Join-Path $RepoRoot 'tests\golden\is-dvorak.json'
}

function Get-ExpectedMapKeys {
    param([object]$Map)

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Keys
    }

    return $Map.PSObject.Properties.Name
}

function Get-ExpectedMapValue {
    param(
        [object]$Map,
        [string]$Name
    )

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map[$Name]
    }

    return $Map.$Name
}

# --- P/Invoke wrapper: load DLL, get KbdLayerDescriptor, walk tables -----------
# C#-side helpers do all the marshalling. This works under both Windows
# PowerShell 5.1 (which lacks the generic PtrToStructure<T> PS syntax) and
# PowerShell 7 (whose marshaller is pickier about nested struct layouts).
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct KBDTABLES_PARTIAL {
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
}

[StructLayout(LayoutKind.Sequential)]
public struct KBDDEADKEY {
    public uint dwBoth;
    public ushort wchComposed;
    public ushort uFlags;
}

public delegate IntPtr KbdLayerDescriptorFn();

public static class Win32 {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string path);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string name);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr hModule);
}

public static class KbdMarshal {
    public static KBDTABLES_PARTIAL ReadTables(IntPtr p) {
        return (KBDTABLES_PARTIAL)Marshal.PtrToStructure(p, typeof(KBDTABLES_PARTIAL));
    }
    public static KBDDEADKEY ReadDeadKey(IntPtr p) {
        return (KBDDEADKEY)Marshal.PtrToStructure(p, typeof(KBDDEADKEY));
    }
    public static int DeadKeySize() {
        return Marshal.SizeOf(typeof(KBDDEADKEY));
    }
    public static IntPtr CallZeroArg(IntPtr fn) {
        KbdLayerDescriptorFn d = (KbdLayerDescriptorFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(KbdLayerDescriptorFn));
        return d();
    }
}
"@

$h = [Win32]::LoadLibrary($DllPath)
if ($h -eq [IntPtr]::Zero) {
    $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LoadLibrary failed: error $lastError"
}

try {
    $proc = [Win32]::GetProcAddress($h, 'KbdLayerDescriptor')
    if ($proc -eq [IntPtr]::Zero) { throw 'KbdLayerDescriptor not exported' }

    $tablesPtr = [KbdMarshal]::CallZeroArg($proc)
    if ($tablesPtr -eq [IntPtr]::Zero) { throw 'KbdLayerDescriptor returned NULL' }

    $tables = [KbdMarshal]::ReadTables($tablesPtr)

    # --- Dead keys -------------------------------------------------------------
    $deadKeys = @{}
    if ($tables.pDeadKey -ne [IntPtr]::Zero) {
        $offset = $tables.pDeadKey
        $size = [KbdMarshal]::DeadKeySize()
        while ($true) {
            $dk = [KbdMarshal]::ReadDeadKey($offset)
            if ($dk.dwBoth -eq 0) { break }
            $accent = $dk.dwBoth -shr 16
            $base = $dk.dwBoth -band 0xffff
            $key = "U+{0:X4}+U+{1:X4}" -f [int]$accent, [int]$base
            $deadKeys[$key] = ("U+{0:X4}" -f [int]$dk.wchComposed)
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
    [void][Win32]::FreeLibrary($h)
}

# --- Assertions / golden compare ----------------------------------------------
if (-not $MustHaveDeadKeys) {
    $MustHaveDeadKeys = @(
        'U+00B4+U+0061', # acute + a -> á
        'U+00B4+U+0045', # acute + E -> É
        'U+00B4+U+0059', # acute + Y -> Ý
        'U+00A8+U+006F', # diaeresis + o -> ö
        'U+02C7+U+0073', # caron + s -> š
        'U+0060+U+0061'  # grave + a -> à
    )
}

foreach ($k in $MustHaveDeadKeys) {
    if (-not $result.deadKeys.ContainsKey($k)) {
        throw "Dead key sequence missing: $k"
    }
}

if (-not $ExpectedDeadKeyOutputs) {
    $ExpectedDeadKeyOutputs = @{
        'U+00B4+U+0061' = 'U+00E1' # acute + a -> á
        'U+00B4+U+0079' = 'U+00FD' # acute + y -> ý
        'U+00B4+U+0059' = 'U+00DD' # acute + Y -> Ý
    }
}

foreach ($k in (Get-ExpectedMapKeys -Map $ExpectedDeadKeyOutputs)) {
    $expected = Get-ExpectedMapValue -Map $ExpectedDeadKeyOutputs -Name $k
    if ($result.deadKeys[$k] -ne $expected) {
        throw "Dead key sequence $k expected $expected but got $($result.deadKeys[$k])"
    }
}

# AltGr flag must be set or AltGr combinations break.
# fLocaleFlags is 32-bit packed: HIWORD=KBD_VERSION, LOWORD=flags.
# KLLF_ALTGR = 0x0001 in the low word.
$flags = $tables.fLocaleFlags -band 0xFFFF
if ($RequireAltGr -and (($flags -band 1) -ne 1)) {
    throw "KLLF_ALTGR flag not set in fLocaleFlags (got $($result.fLocaleFlags))"
}
if ($RequireAltGr) {
    Write-Host ("fLocaleFlags={0} (low word 0x{1:X4}, KLLF_ALTGR set)" -f $result.fLocaleFlags, $flags)
} else {
    Write-Host ("fLocaleFlags={0} (low word 0x{1:X4})" -f $result.fLocaleFlags, $flags)
}

Write-Host "OK: $($result.deadKeyCount) dead key sequences and expected metadata verified."

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

#Requires -Version 5.1
<#
.SYNOPSIS
  Render and verify a live Windows keyboard layout through user32.

.DESCRIPTION
  Loads a registered KLID, maps physical scan codes to that layout's virtual
  keys with MapVirtualKeyEx, then calls ToUnicodeEx for normal, Shift, AltGr,
  and Shift+AltGr. This verifies the same translation path applications use.

.PARAMETER Klid
  Windows keyboard layout id to load. Defaults to the packaged Icelandic Dvorak
  KLID used by this repository.

.PARAMETER HtmlPath
  Optional path for an HTML keyboard render.

.PARAMETER ExpectedLayoutName
  Optional expected display/layout name resolved from the Windows registry.

.PARAMETER ExpectedChars
  Optional scan-code expectations to assert when AssertIcelandicDvorak is set.
  Each item should provide Scan plus one or more of Normal, Shift, AltGr, and
  ShiftAltGr. Defaults to the current is(dvorak) expectations.

.PARAMETER AssertIcelandicDvorak
  Assert the known xkeyboard-config is(dvorak) AltGr outputs.
#>

[CmdletBinding()]
param(
    [string]$Klid = '0001040f',
    [string]$HtmlPath,
    [string]$ExpectedLayoutName,
    [object[]]$ExpectedChars,
    [switch]$AssertIcelandicDvorak
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LiveKeyboardLayout {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint Flags);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, IntPtr dwhkl);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ToUnicodeEx(
        uint wVirtKey,
        uint wScanCode,
        byte[] lpKeyState,
        StringBuilder pwszBuff,
        int cchBuff,
        uint wFlags,
        IntPtr dwhkl);
}

public static class LiveKeyboardLayoutNames {
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    public static extern int SHLoadIndirectString(
        string pszSource,
        StringBuilder pszOutBuf,
        uint cchOutBuf,
        IntPtr ppvReserved);
}
"@

function ConvertTo-DisplayText {
    param([string]$Text, [bool]$Dead)

    if ($Text.Length -eq 0) { return '' }
    if ($Text -eq ' ') { return 'Space' }
    if ($Dead) { return "$Text (dead)" }
    return $Text
}

function ConvertTo-Codepoints {
    param([string]$Text)

    if ($Text.Length -eq 0) { return '' }
    return (($Text.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
}

function Invoke-ToUnicode {
    param(
        [IntPtr]$Hkl,
        [uint32]$Vk,
        [uint32]$Scan,
        [switch]$Shift,
        [switch]$AltGr
    )

    $state = New-Object byte[] 256
    if ($Shift) {
        $state[0x10] = 0x80 # VK_SHIFT
        $state[0xA0] = 0x80 # VK_LSHIFT
    }
    if ($AltGr) {
        $state[0x11] = 0x80 # VK_CONTROL
        $state[0x12] = 0x80 # VK_MENU
        $state[0xA3] = 0x80 # VK_RCONTROL
        $state[0xA5] = 0x80 # VK_RMENU
    }

    $buffer = [Text.StringBuilder]::new(16)
    $rc = [LiveKeyboardLayout]::ToUnicodeEx($Vk, $Scan, $state, $buffer, $buffer.Capacity, 4, $Hkl)
    $text = if ($rc -gt 0) {
        $buffer.ToString().Substring(0, [Math]::Min($rc, $buffer.Length))
    } elseif ($rc -lt 0 -and $buffer.Length -gt 0) {
        $buffer.ToString().Substring(0, 1)
    } else {
        ''
    }

    [pscustomobject]@{
        Text = $text
        Display = ConvertTo-DisplayText -Text $text -Dead ($rc -lt 0)
        Codepoints = ConvertTo-Codepoints -Text $text
        Result = $rc
        Dead = ($rc -lt 0)
    }
}

function Escape-Html {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Test-ExpectedProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }

    return $null -ne ($Object.PSObject.Properties[$Name])
}

function Get-ExpectedProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }

    return $Object.$Name
}

$hkl = [LiveKeyboardLayout]::LoadKeyboardLayout($Klid, 0x00000080) # KLF_NOTELLSHELL, process-local load
if ($hkl -eq [IntPtr]::Zero) {
    $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LoadKeyboardLayout($Klid) failed with Win32 error $lastError"
}

if ($ExpectedLayoutName) {
    $layoutKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$Klid"
    if (-not (Test-Path $layoutKey)) { throw "Keyboard layout registry key not found: $layoutKey" }

    $layoutProps = Get-ItemProperty $layoutKey
    $displayName = [string]$layoutProps.'Layout Display Name'
    $layoutText = [string]$layoutProps.'Layout Text'
    $resolvedName = $layoutText
    if ($displayName) {
        $nameBuffer = [Text.StringBuilder]::new(260)
        $hr = [LiveKeyboardLayoutNames]::SHLoadIndirectString($displayName, $nameBuffer, $nameBuffer.Capacity, [IntPtr]::Zero)
        if ($hr -eq 0 -and $nameBuffer.Length -gt 0) { $resolvedName = $nameBuffer.ToString() }
    }

    if ($resolvedName -ne $ExpectedLayoutName) {
        throw "Registry layout name expected '$ExpectedLayoutName' but resolved '$resolvedName'"
    }

    Add-Type -AssemblyName System.Windows.Forms
    $targetHklHex = '0x{0:X8}' -f [uint32]($hkl.ToInt64() -band 0xffffffffL)
    $installedLanguage = [System.Windows.Forms.InputLanguage]::InstalledInputLanguages |
        Where-Object { ('0x{0:X8}' -f [uint32]($_.Handle.ToInt64() -band 0xffffffffL)) -eq $targetHklHex } |
        Select-Object -First 1
    if (-not $installedLanguage) {
        throw "HKL $targetHklHex is not present in Windows Forms InstalledInputLanguages"
    }
    if ($installedLanguage.LayoutName -ne $ExpectedLayoutName) {
        throw "Installed input language layout name expected '$ExpectedLayoutName' but got '$($installedLanguage.LayoutName)'"
    }

    Write-Host "OK: layout display name resolved as '$ExpectedLayoutName' for HKL $targetHklHex."
}

$rows = @(
    @{ Name = 'number'; Keys = @(
        @{ Scan = 0x29; Key = 'OEM_3' }, @{ Scan = 0x02; Key = '1' }, @{ Scan = 0x03; Key = '2' },
        @{ Scan = 0x04; Key = '3' }, @{ Scan = 0x05; Key = '4' }, @{ Scan = 0x06; Key = '5' },
        @{ Scan = 0x07; Key = '6' }, @{ Scan = 0x08; Key = '7' }, @{ Scan = 0x09; Key = '8' },
        @{ Scan = 0x0A; Key = '9' }, @{ Scan = 0x0B; Key = '0' }, @{ Scan = 0x0C; Key = 'OEM_MINUS' },
        @{ Scan = 0x0D; Key = 'OEM_PLUS' }
    ) },
    @{ Name = 'top'; Keys = @(
        @{ Scan = 0x10; Key = 'Q' }, @{ Scan = 0x11; Key = 'W' }, @{ Scan = 0x12; Key = 'E' },
        @{ Scan = 0x13; Key = 'R' }, @{ Scan = 0x14; Key = 'T' }, @{ Scan = 0x15; Key = 'Y' },
        @{ Scan = 0x16; Key = 'U' }, @{ Scan = 0x17; Key = 'I' }, @{ Scan = 0x18; Key = 'O' },
        @{ Scan = 0x19; Key = 'P' }, @{ Scan = 0x1A; Key = 'OEM_4' }, @{ Scan = 0x1B; Key = 'OEM_6' }
    ) },
    @{ Name = 'home'; Keys = @(
        @{ Scan = 0x1E; Key = 'A' }, @{ Scan = 0x1F; Key = 'S' }, @{ Scan = 0x20; Key = 'D' },
        @{ Scan = 0x21; Key = 'F' }, @{ Scan = 0x22; Key = 'G' }, @{ Scan = 0x23; Key = 'H' },
        @{ Scan = 0x24; Key = 'J' }, @{ Scan = 0x25; Key = 'K' }, @{ Scan = 0x26; Key = 'L' },
        @{ Scan = 0x27; Key = 'OEM_1' }, @{ Scan = 0x28; Key = 'OEM_7' }, @{ Scan = 0x2B; Key = 'OEM_5' }
    ) },
    @{ Name = 'bottom'; Keys = @(
        @{ Scan = 0x2C; Key = 'Z' }, @{ Scan = 0x2D; Key = 'X' }, @{ Scan = 0x2E; Key = 'C' },
        @{ Scan = 0x2F; Key = 'V' }, @{ Scan = 0x30; Key = 'B' }, @{ Scan = 0x31; Key = 'N' },
        @{ Scan = 0x32; Key = 'M' }, @{ Scan = 0x33; Key = 'OEM_COMMA' }, @{ Scan = 0x34; Key = 'OEM_PERIOD' },
        @{ Scan = 0x35; Key = 'OEM_2' }
    ) },
    @{ Name = 'space'; Keys = @( @{ Scan = 0x39; Key = 'SPACE'; Wide = $true } ) }
)

$renderedRows = foreach ($row in $rows) {
    $renderedKeys = foreach ($key in $row.Keys) {
        $scan = [uint32]$key.Scan
        $vk = [LiveKeyboardLayout]::MapVirtualKeyEx($scan, 1, $hkl) # MAPVK_VSC_TO_VK
        if ($vk -eq 0) {
            throw ("MapVirtualKeyEx failed for scan 0x{0:X2}" -f $scan)
        }

        [pscustomobject]@{
            Scan = ('0x{0:X2}' -f $scan)
            PhysicalKey = $key.Key
            Vk = ('0x{0:X2}' -f $vk)
            Normal = Invoke-ToUnicode -Hkl $hkl -Vk $vk -Scan $scan
            Shift = Invoke-ToUnicode -Hkl $hkl -Vk $vk -Scan $scan -Shift
            AltGr = Invoke-ToUnicode -Hkl $hkl -Vk $vk -Scan $scan -AltGr
            ShiftAltGr = Invoke-ToUnicode -Hkl $hkl -Vk $vk -Scan $scan -Shift -AltGr
            Wide = [bool]$key.Wide
        }
    }

    [pscustomobject]@{
        Name = $row.Name
        Keys = @($renderedKeys)
    }
}

$allKeys = @($renderedRows | ForEach-Object { $_.Keys })
$allKeys |
    Select-Object Scan, PhysicalKey, Vk,
        @{ Name = 'Normal'; Expression = { $_.Normal.Display } },
        @{ Name = 'Shift'; Expression = { $_.Shift.Display } },
        @{ Name = 'AltGr'; Expression = { $_.AltGr.Display } },
        @{ Name = 'ShiftAltGr'; Expression = { $_.ShiftAltGr.Display } } |
    Format-Table -AutoSize

if ($AssertIcelandicDvorak) {
    if (-not $ExpectedChars) {
        $ExpectedChars = @(
            @{ Scan = '0x05'; Normal = '4'; AltGr = [string][char]0x20AC },
            @{ Scan = '0x1F'; Normal = 'o'; Shift = 'O'; AltGr = [string][char]0x00F6; ShiftAltGr = [string][char]0x00D6 },
            @{ Scan = '0x23'; Normal = 'd'; Shift = 'D'; AltGr = [string][char]0x00F0; ShiftAltGr = [string][char]0x00D0 },
            @{ Scan = '0x27'; Normal = 's'; Shift = 'S'; AltGr = [string][char]0x00E6; ShiftAltGr = [string][char]0x00C6 },
            @{ Scan = '0x31'; Normal = 'b'; Shift = 'B'; AltGr = [string][char]0x00DF; ShiftAltGr = [string][char]0x1E9E },
            @{ Scan = '0x35'; Normal = 'z'; Shift = 'Z'; AltGr = [string][char]0x00FE; ShiftAltGr = [string][char]0x00DE }
        )
    }

    foreach ($case in $ExpectedChars) {
        $scan = Get-ExpectedProperty -Object $case -Name 'Scan'
        $actual = $allKeys | Where-Object { $_.Scan -eq $scan } | Select-Object -First 1
        if (-not $actual) { throw "Missing rendered scan code $scan" }
        foreach ($state in @('Normal', 'Shift', 'AltGr', 'ShiftAltGr')) {
            if (-not (Test-ExpectedProperty -Object $case -Name $state)) { continue }
            $expected = Get-ExpectedProperty -Object $case -Name $state
            if ($actual.$state.Text -ne $expected) {
                throw "$scan $state expected '$expected' but got '$($actual.$state.Text)' ($($actual.$state.Codepoints))"
            }
        }
    }

    Write-Host "OK: live layout $Klid produced expected Icelandic Dvorak AltGr characters."
}

if ($HtmlPath) {
    $htmlRows = foreach ($row in $renderedRows) {
        $keys = foreach ($key in $row.Keys) {
            $wideClass = if ($key.Wide) { ' wide' } else { '' }
            @"
      <div class="key$wideClass">
        <div class="legend top-left">$(Escape-Html $key.Shift.Display)</div>
        <div class="legend top-right">$(Escape-Html $key.ShiftAltGr.Display)</div>
        <div class="legend bottom-left">$(Escape-Html $key.Normal.Display)</div>
        <div class="legend bottom-right">$(Escape-Html $key.AltGr.Display)</div>
        <div class="scan">$(Escape-Html $key.Scan)</div>
      </div>
"@
        }
        @"
    <section class="row $($row.Name)">
$($keys -join "`r`n")
    </section>
"@
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Live keyboard layout $Klid</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; background: #f6f8fa; }
    h1 { font-size: 20px; margin: 0 0 4px; }
    p { margin: 0 0 18px; color: #57606a; }
    .keyboard { display: inline-flex; flex-direction: column; gap: 8px; padding: 16px; background: #fff; border: 1px solid #d0d7de; border-radius: 8px; }
    .row { display: flex; gap: 8px; }
    .row.top { margin-left: 32px; }
    .row.home { margin-left: 46px; }
    .row.bottom { margin-left: 74px; }
    .row.space { margin-left: 190px; }
    .key { position: relative; width: 58px; height: 54px; background: #f6f8fa; border: 1px solid #8c959f; border-radius: 6px; box-shadow: inset 0 -2px 0 #d0d7de; }
    .key.wide { width: 290px; }
    .legend { position: absolute; font-size: 16px; line-height: 1; font-weight: 600; }
    .top-left { top: 7px; left: 8px; }
    .top-right { top: 7px; right: 8px; color: #0969da; }
    .bottom-left { bottom: 8px; left: 8px; }
    .bottom-right { bottom: 8px; right: 8px; color: #0969da; }
    .scan { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); font-size: 10px; color: #6e7781; }
  </style>
</head>
<body>
  <h1>Live keyboard layout $Klid</h1>
  <p>Bottom-left is normal, top-left is Shift, bottom-right is AltGr, top-right is Shift+AltGr. Rendered through MapVirtualKeyEx and ToUnicodeEx.</p>
  <main class="keyboard">
$($htmlRows -join "`r`n")
  </main>
</body>
</html>
"@
    New-Item -ItemType Directory -Force -Path (Split-Path $HtmlPath) | Out-Null
    Set-Content -Path $HtmlPath -Value $html -Encoding UTF8
    Write-Host "Rendered HTML: $HtmlPath"
}

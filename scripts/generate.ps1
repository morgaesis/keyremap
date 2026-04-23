#Requires -Version 5.1
<#
.SYNOPSIS
  Regenerate generated/<variant>/{kbdisdv*.c,h,def,rc} from src/kbdisdv.klc
  via kbdutool.exe, with per-variant post-processing to produce alternate
  CapsLock behaviors (AltGr, Esc, Ctrl) in addition to the default layout.

.DESCRIPTION
  Source of truth: src/kbdisdv.klc. kbdutool emits C/H/DEF/RC from it, and
  we apply small regex patches (see scripts/variants.ps1) to swap the
  CapsLock virtual-key mapping for the variant DLLs.

  Outputs land under generated/<variant>/<BaseName>.{c,h,def,rc}. That
  directory is gitignored — the kbdutool output carries a Microsoft
  copyright notice we don't distribute.

  Prerequisites:
    - Microsoft Keyboard Layout Creator 1.4 installed (kbdutool.exe).
      CI silent-installs it via scripts/install-msklc.ps1.

.PARAMETER Variant
  Which variant to (re)generate. Defaults to 'all'. Pass one of:
  default, caps-altgr, caps-esc, caps-ctrl.
#>

[CmdletBinding()]
param(
    [string]$Variant = 'all'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'variants.ps1')

$KlcSrc   = Join-Path $RepoRoot 'src\kbdisdv.klc'
$GenRoot  = Join-Path $RepoRoot 'generated'
$KbdUtool = "${env:ProgramFiles(x86)}\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe"

if (-not (Test-Path $KbdUtool)) {
    throw "kbdutool.exe not found at $KbdUtool. Install MSKLC 1.4 or run scripts/install-msklc.ps1."
}
if (-not (Test-Path $KlcSrc)) {
    throw "Source KLC missing: $KlcSrc"
}

$variantsToBuild = if ($Variant -eq 'all') { Get-VariantNames } else { @($Variant) }

foreach ($vname in $variantsToBuild) {
    $spec = Get-VariantSpec -Name $vname
    $outDir = Join-Path $GenRoot $vname
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    # Derive a variant-specific KLC with the desired KBD base name and
    # Description. Simple textual substitution: first non-empty line is
    # `KBD <basename> "<description>"` which kbdutool uses for filenames
    # and metadata.
    $klcText = Get-Content $KlcSrc -Raw -Encoding UTF8
    $klcText = $klcText -replace '^KBD\s+kbdisdv\s+"[^"]+"', ('KBD ' + $spec.BaseName + ' "' + $spec.DisplayName + '"')
    $variantKlc = Join-Path $outDir ($spec.BaseName + '.klc')

    # kbdutool -u requires UTF-16 LE + BOM + CRLF
    $utf16 = [System.Text.Encoding]::Unicode
    $bytes = $utf16.GetPreamble() + $utf16.GetBytes(($klcText -replace "`r?`n", "`r`n"))
    [System.IO.File]::WriteAllBytes($variantKlc, $bytes)

    Write-Host "=== Generating variant: $vname ==="
    Push-Location $outDir
    try {
        & $KbdUtool -u -s ($spec.BaseName + '.klc') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "kbdutool failed for $vname (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }

    # Lower-case the extensions that kbdutool writes in uppercase
    Get-ChildItem $outDir -Include '*.C', '*.H', '*.DEF', '*.RC' -File | ForEach-Object {
        $new = $_.BaseName + $_.Extension.ToLower()
        Rename-Item -LiteralPath $_.FullName -NewName $new -Force
    }

    # Apply patches
    foreach ($patch in $spec.Patches) {
        $file = Join-Path $outDir ($ExecutionContext.InvokeCommand.ExpandString($patch.File))
        if (-not (Test-Path $file)) { throw "Patch target missing: $file" }
        $text = Get-Content $file -Raw
        $newText = [regex]::Replace($text, $patch.Find, $patch.Replace)
        if ($text -eq $newText) { throw "Patch did not match anything in $file — regex may need updating" }
        Set-Content -Path $file -Value $newText -NoNewline -Encoding ASCII
        Write-Host "Patched: $file"
    }

    Write-Host "==> variant $vname produced under: $outDir"
}

Write-Host ""
Write-Host "Done. Generated variants: $($variantsToBuild -join ', ')"

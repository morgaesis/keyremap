#Requires -Version 5.1
<#
.SYNOPSIS
  Silent-install Microsoft Keyboard Layout Creator 1.4 so kbdutool.exe is
  available on PATH for the generate step.

.DESCRIPTION
  MSKLC 1.4 is a free Microsoft download that ships the `kbdutool.exe` CLI
  we need. It is NOT redistributed by this repository; we download it
  fresh from microsoft.com on each CI run (cached after first success).

  This script is used by CI. Local developers typically install MSKLC from
  microsoft.com manually.
#>

[CmdletBinding()]
param(
    [string]$MsklcUrl = 'https://download.microsoft.com/download/6/f/5/6f5ce43a-e892-4fd1-b9a6-1a0cbb64e6e2/MSKLC.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installed = 'C:\Program Files (x86)\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe'
if (Test-Path $installed) {
    Write-Host "MSKLC already present: $installed"
    return
}

$tmp = Join-Path $env:TEMP "msklc-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $exe = Join-Path $tmp 'MSKLC.exe'
    Write-Host "Downloading $MsklcUrl -> $exe"
    Invoke-WebRequest -Uri $MsklcUrl -OutFile $exe -UseBasicParsing
    Write-Host "Downloaded $((Get-Item $exe).Length) bytes"

    # MSKLC.exe is an InstallShield self-extractor wrapping an MSI.
    # Canonical silent-install: /s (InstallShield silent) /v"/qn /norestart"
    # (args passed through to msiexec).
    $argList = @('/s', '/v"/qn /norestart"')
    Write-Host "Running: $exe $($argList -join ' ')"
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        # Fall back to two-step extract + msiexec in case InstallShield rejects the form
        Write-Warning "Single-step silent install returned $($p.ExitCode); trying extract + msiexec"
        $ext = Join-Path $tmp 'extract'
        New-Item -ItemType Directory -Force -Path $ext | Out-Null
        Start-Process -FilePath $exe -ArgumentList @('/s', '/x', "/b`"$ext`"", '/v"/qn"') -Wait -NoNewWindow
        $msi = Get-ChildItem -Path $ext -Filter 'MSKLC.msi' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $msi) { throw "Could not extract MSKLC.msi under $ext" }
        $p2 = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi.FullName, '/qn', '/norestart') -Wait -PassThru -NoNewWindow
        if ($p2.ExitCode -ne 0) { throw "msiexec failed with exit $($p2.ExitCode)" }
    }

    if (-not (Test-Path $installed)) {
        throw "kbdutool.exe missing after install; expected $installed"
    }
    Write-Host "MSKLC installed: $(Get-Item $installed | Select-Object -ExpandProperty FullName)"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

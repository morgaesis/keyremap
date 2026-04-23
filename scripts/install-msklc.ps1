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
    [string]$MsklcUrl = 'https://download.microsoft.com/download/5/6/d/56D63279-8C2D-498D-B30A-DB40293EDA10/MSKLC.exe'
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

    # MSKLC.exe is a self-extracting archive containing MSKLC.msi plus
    # supporting files. `/quiet /norestart` silent-installs directly.
    $argList = '/quiet', '/norestart'
    Write-Host "Running: $exe $($argList -join ' ')"
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        throw "MSKLC installer exited with code $($p.ExitCode)"
    }

    if (-not (Test-Path $installed)) {
        throw "kbdutool.exe missing after install; expected $installed"
    }
    Write-Host "MSKLC installed: $(Get-Item $installed | Select-Object -ExpandProperty FullName)"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

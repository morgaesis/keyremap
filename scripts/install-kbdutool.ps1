#Requires -Version 5.1
<#
.SYNOPSIS
  Install MSKLC 1.4 so kbdutool.exe is available.

.DESCRIPTION
  This downloads Microsoft's MSKLC installer and runs it silently. The repo
  uses only kbdutool.exe from MSKLC; it does not use the MSKLC GUI or setup
  package output for keyboard installation.
#>

[CmdletBinding()]
param(
    [string]$MsklcUrl = 'https://download.microsoft.com/download/6/f/5/6f5ce43a-e892-4fd1-b9a6-1a0cbb64e6e2/MSKLC.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installed = 'C:\Program Files (x86)\Microsoft Keyboard Layout Creator 1.4\bin\i386\kbdutool.exe'
if (Test-Path $installed) {
    Write-Host "kbdutool already present: $installed"
    return
}

$tmp = Join-Path $env:TEMP "msklc-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $exe = Join-Path $tmp 'MSKLC.exe'
    Invoke-WebRequest -Uri $MsklcUrl -OutFile $exe -UseBasicParsing

    $args = @('/s', '/v"/qn /norestart"')
    $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        throw "MSKLC silent install failed with exit $($p.ExitCode)"
    }
    if (-not (Test-Path $installed)) {
        throw "kbdutool.exe missing after install; expected $installed"
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$manifestPath = Join-Path $RepoRoot 'data\layouts.json'
$candidatePath = Join-Path $RepoRoot 'data\xkb-windows-candidates.json'
$outPath = Join-Path $RepoRoot 'installer\layouts.ini'

$packaged = @{}
if (Test-Path $manifestPath) {
    foreach ($item in (Get-Content $manifestPath -Raw | ConvertFrom-Json)) {
        $packaged[$item.id] = $item
    }
}

$rows = New-Object System.Collections.Generic.List[object]
if (Test-Path $candidatePath) {
    foreach ($candidate in (Get-Content $candidatePath -Raw | ConvertFrom-Json)) {
        $layout = [string]$candidate.xkb.layout
        $variant = [string]$candidate.xkb.variant
        $id = if ($variant) { "$layout-$variant" } else { $layout }
        $id = ($id.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        $pkg = $packaged[$id]
        $rows.Add([pscustomobject]@{
            Id = $id
            DisplayName = if ($pkg) { [string]$pkg.displayName } else { [string]$candidate.xkb.description }
            Xkb = if ($variant) { "$layout($variant)" } else { $layout }
            WindowsExists = ($candidate.match.status -eq 'candidate')
            Packaged = ($null -ne $pkg -and [bool]$pkg.packaged)
            InstalledDll = if ($pkg) { [string]$pkg.dllName } else { '' }
        })
    }
} else {
    foreach ($pkg in $packaged.Values) {
        $rows.Add([pscustomobject]@{
            Id = [string]$pkg.id
            DisplayName = [string]$pkg.displayName
            Xkb = "$($pkg.xkbLayout)($($pkg.xkbVariant))"
            WindowsExists = [bool]$pkg.windowsAlreadyExists
            Packaged = [bool]$pkg.packaged
            InstalledDll = [string]$pkg.dllName
        })
    }
}

$rows = @($rows | Sort-Object DisplayName, Xkb)
New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('[Layouts]')
$lines.Add("Count=$($rows.Count)")
for ($i = 0; $i -lt $rows.Count; $i++) {
    $n = $i + 1
    $row = $rows[$i]
    $lines.Add("Id$n=$($row.Id)")
    $lines.Add("Name$n=$($row.DisplayName)")
    $lines.Add("Xkb$n=$($row.Xkb)")
    $lines.Add("WindowsExists$n=$([int][bool]$row.WindowsExists)")
    $lines.Add("Packaged$n=$([int][bool]$row.Packaged)")
    $lines.Add("Dll$n=$($row.InstalledDll)")
}
$lines | Set-Content -Encoding UTF8 $outPath
Write-Host "Wrote $outPath"

#requires -Version 7
<#
Ingest export packages one at a time, reclaiming disk between them.

A quarter's export can be far larger than the disk can hold all at once - 2026 Q1 came
back as six packages totalling 53 GB - and .msg barely compresses, so extraction needs
roughly as much space again. Splitting the EXPORT into narrower date ranges is one answer,
but it means re-exporting and re-downloading tens of gigabytes that are already on disk.

This is the other answer: keep the download, process it a package at a time. Each package
is extracted, keyed, uploaded and then deleted before the next begins, so the working set
is one package rather than the whole quarter.

Safe to interrupt and re-run. ingest-run.ps1's checkpoint means an already-uploaded
package is skipped in seconds, and a package is only deleted after its upload reports no
errors.

  ./ingest-packages.ps1 -Source C:\Users\admin-MTSG3\export
  ./ingest-packages.ps1 -Source C:\Users\admin-MTSG3\export -KeepExtracted   # debugging
#>
param(
  [Parameter(Mandatory)][string]$Source,
  [string]$Work = (Join-Path (Split-Path $Source -Parent) 'rse-ingest-work'),
  [switch]$KeepExtracted,
  [int]$Parallel = 12
)
$ErrorActionPreference = 'Stop'

$staging = Join-Path $Work '_one'
New-Item -ItemType Directory -Force -Path $Work, $staging | Out-Null

# Reports packages carry no mail; ingest-run.ps1 skips them anyway, but there is no reason
# to give one a whole pass of its own.
$packages = Get-ChildItem $Source -Filter *.zip |
            Where-Object { $_.Name -notlike 'Reports-*' } |
            Sort-Object Name

Write-Host "$($packages.Count) package(s) to process"
$n = 0
foreach ($pkg in $packages) {
  $n++
  $name = [IO.Path]::GetFileNameWithoutExtension($pkg.Name)
  $extracted = Join-Path $Work $name
  Write-Host ""
  Write-Host ("=== [{0}/{1}] {2}  ({3:N1} GB) ===" -f $n, $packages.Count, $name, ($pkg.Length/1GB))

  # Present exactly one package to ingest-run.ps1. A directory junction rather than a copy:
  # the file is already on disk and copying 10 GB to look at it would defeat the point.
  Get-ChildItem $staging -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.LinkType) { $_.Delete() } else { Remove-Item $_.FullName -Recurse -Force }
  }
  $link = Join-Path $staging $pkg.Name
  cmd /c mklink /H "$link" "$($pkg.FullName)" | Out-Null
  if (-not (Test-Path $link)) { Copy-Item $pkg.FullName $link }   # different volume, fall back

  $free = (Get-Item $Work).PSDrive.Free / 1GB
  Write-Host ("  free before: {0:N1} GB" -f $free)

  & (Join-Path $PSScriptRoot 'ingest-run.ps1') -Source $staging -Work $Work -Parallel $Parallel -Execute
  $ok = $LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE

  if ($ok -and -not $KeepExtracted -and (Test-Path $extracted)) {
    Write-Host "  uploaded - reclaiming $name"
    [IO.Directory]::Delete($extracted, $true)
  } elseif (-not $ok) {
    Write-Warning "  package $name did not complete cleanly - leaving it extracted for inspection"
  }
  Write-Host ("  free after : {0:N1} GB" -f ((Get-Item $Work).PSDrive.Free / 1GB))
}

Get-ChildItem $staging -Force -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_.LinkType) { $_.Delete() } else { Remove-Item $_.FullName -Recurse -Force }
}
Write-Host ""
Write-Host "all packages processed. Checkpoint: $((Get-Content (Join-Path $Work 'done.txt')).Count) tokens uploaded."

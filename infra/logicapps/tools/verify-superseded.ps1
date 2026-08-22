#requires -Version 7
<#
Prove that "superseded" really means "the same message exists in new-format".

Byte size cannot decide this: re-fetching the same message from Graph yields a .eml that
differs by a few hundred bytes (transport headers vary between fetches), so equal-size is
too strict and unequal-size proves nothing.

RFC 5322 Message-ID does decide it. It is assigned by the originating mail system and is
carried unchanged in every copy, so if the old blob's Message-ID appears among the
new-format blobs sharing its stem, that message demonstrably still exists in the archive and
the old copy is genuinely redundant.

Read-only. Deletes nothing.
#>
param([int]$Sample = 25)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tmp = Join-Path $sp 'verify-tmp'
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp | Out-Null }

$all = Get-Content (Join-Path $sp 'allblobs2.txt')
$sup = Get-Content (Join-Path $sp 'superseded.txt')

$newIx = @{}
foreach ($p in $all) {
  if ($p -notlike '*/Emails/*.eml' -or $p -like '*/Emails/Attachments/*') { continue }
  $parts = $p -split '/'; $file = $parts[-1] -replace '\.eml$',''
  $m = [regex]::Match($file, '^(.*?)\s\[([^\]]+)\]$')
  if (-not $m.Success) { continue }
  $stem = $m.Groups[1].Value.Trim(); if ($stem.Length -gt 150) { $stem = $stem.Substring(0,150).Trim() }
  $k = "$($parts[0])|$stem"
  if (-not $newIx.ContainsKey($k)) { $newIx[$k] = @() }
  $newIx[$k] += $p
}

function Get-MessageId([string]$blob) {
  $f = Join-Path $tmp ([guid]::NewGuid().ToString('N') + '.eml')
  try {
    & $az storage blob download --account-name samatters --container-name matters `
        --name $blob --file $f --auth-mode login --no-progress 2>$null | Out-Null
    if (-not (Test-Path $f)) { return $null }
    # Read raw bytes, not lines. A 400-line head missed the header on 15 of 25 samples:
    # these .eml files carry long DKIM/ARC/References blocks, and some begin with a MIME
    # preamble, so Message-ID can sit well past any fixed line count. 256 KB clears it
    # without loading whole multi-megabyte messages.
    $fs = [IO.File]::OpenRead($f)
    try {
      $len = [int][math]::Min(262144, $fs.Length)
      $buf = New-Object byte[] $len
      [void]$fs.Read($buf, 0, $len)
      $text = [Text.Encoding]::ASCII.GetString($buf)
    } finally { $fs.Dispose() }
    $m = [regex]::Match($text, '(?im)^Message-ID\s*:\s*<([^>]+)>')
    if (-not $m.Success) { return $null }
    $m.Groups[1].Value
  } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

$proven = 0; $notFound = 0; $noId = 0; $failures = @()
$picks = $sup | Get-Random -Count $Sample
foreach ($old in $picks) {
  $parts = $old -split '/'; $matter = $parts[0]
  $stem = ($parts[-1] -replace '\.eml$','').Trim(); if ($stem.Length -gt 150) { $stem = $stem.Substring(0,150).Trim() }
  $cands = $newIx["$matter|$stem"]
  if (-not $cands) { $notFound++; $failures += "no candidate: $old"; continue }

  $oldId = Get-MessageId $old
  if (-not $oldId) { $noId++; continue }

  $match = $false
  foreach ($c in $cands) {
    if ((Get-MessageId $c) -eq $oldId) { $match = $true; break }
  }
  if ($match) { $proven++ } else { $failures += "Message-ID $oldId not among $($cands.Count) new copies: $old" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "sampled                       : $Sample"
Write-Host "PROVEN redundant (same Msg-ID): $proven"
Write-Host "no candidate blob             : $notFound"
Write-Host "no Message-ID header readable : $noId"
Write-Host "unproven                      : $($failures.Count)"
if ($failures) { Write-Host ""; Write-Host "failures:"; $failures | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" } }

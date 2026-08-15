#requires -Version 7
<#
Re-file emails sitting in UnsortedMatterCommunication under the matter their subject
actually names.

These are already archived .eml blobs, so this is a server-side blob move, not a mail
replay - there is no Service Bus event to re-raise for them. The blob name is the
sanitised subject, which is what the matcher reads.

Copy is server-side (x-ms-copy-source), so content never travels through this machine.
The source is deleted only after the destination is confirmed present, so an interrupted
run leaves duplicates rather than losing anything.

Attachments under UnsortedMatterCommunication/Emails/Attachments/ are deliberately left
alone: they are keyed by attachment filename with no reference back to their message, so
they cannot be mapped to a matter. The .eml is full MIME and already contains them.
#>
param(
  [int]$Max = 5000,
  [switch]$Execute,          # dry run unless set
  [string]$Account = 'samatters',
  [string]$Container = 'matters',
  [string]$SourcePrefix = 'UnsortedMatterCommunication/Emails/'
)
$ErrorActionPreference = 'Stop'
# The listing is done over REST, not `az storage blob list`, because az mangles the
# names: it warns "Unable to encode the output with cp1252 encoding. Unsupported
# characters are discarded" and then silently drops characters, so the copy source
# 404s on a blob that is really there.
#
# This is not a rare edge case. Measured against a REST listing of the same prefix,
# 122 of 6053 names - 2% - came back from az as something that does not exist. Email
# subjects are full of en dashes and curly quotes, and the discarded character leaves
# a name that looks almost right ("Gasparyan - Meet" for "Gasparyan <U+2013> Meet"),
# which is exactly the kind of near-miss that reads as a data problem rather than a
# tooling one. An earlier estimate of 5 in 2380 was made by testing whether the name
# survived a cp1252 round-trip; that undercounts by 10x, because az also drops
# characters cp1252 can represent perfectly well.
#
# The loss happens inside az before the output reaches PowerShell, so neither
# [Console]::OutputEncoding nor PYTHONIOENCODING helps. REST is the fix.
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$key = (Get-Content "$env:TEMP\sakey.txt" -Raw).Trim()
$fn  = 'https://regexazfunc.azurewebsites.net/api/RegExMattersAzFunc'
$root = "https://$Account.blob.core.windows.net/$Container"

$expiry = (Get-Date).ToUniversalTime().AddHours(4).ToString('yyyy-MM-ddTHH:mm:ssZ')
# 'l' so the same SAS can list; the rest is read/copy/write/delete for the move
$sas = (& $az storage container generate-sas --account-name $Account --account-key $key `
          --name $Container --permissions racwdl --expiry $expiry -o tsv).Trim()
if (-not $sas) { throw 'could not mint a container SAS' }

# Paged REST listing. maxresults caps a *page*, not the result set - NextMarker walks
# the rest - so unlike a literal --num-results cap nothing is silently left behind.
function Get-BlobNames([string]$prefix) {
  $names = New-Object System.Collections.Generic.List[string]
  $marker = ''
  do {
    $u = "$root`?restype=container&comp=list&prefix=$([uri]::EscapeDataString($prefix))&maxresults=5000&$sas"
    if ($marker) { $u += "&marker=$([uri]::EscapeDataString($marker))" }
    # the response is UTF-8 with a BOM, which a bare [xml] cast will not parse
    $xml = [xml]((Invoke-WebRequest -Uri $u).Content -replace "^﻿", '')
    foreach ($b in $xml.EnumerationResults.Blobs.Blob) { $names.Add($b.Name) }
    $marker = $xml.EnumerationResults.NextMarker
  } while ($marker)
  $names
}

# top-level .eml only - never the Attachments/ subfolder
$emls = @(Get-BlobNames $SourcePrefix | Where-Object {
  $_ -like '*.eml' -and ($_ -replace [regex]::Escape($SourcePrefix), '') -notlike '*/*'
} | ForEach-Object { [pscustomobject]@{ name = $_ } })
Write-Host "unsorted .eml blobs: $($emls.Count)"

$moved = 0; $skipped = 0; $failed = 0
foreach ($b in ($emls | Select-Object -First $Max)) {
  $leaf = $b.name -replace [regex]::Escape($SourcePrefix), ''
  $subject = $leaf -replace '\.eml$', ''

  try {
    $r = Invoke-RestMethod -Method Post -Uri $fn -TimeoutSec 30 -ContentType 'application/json' `
           -Body (@{ strData = $subject } | ConvertTo-Json -Compress)
  } catch { $failed++; continue }

  # Only a strict RSE File No is trusted. A Case/Claim number needs the lookup list to map
  # it onto a matter, and this script has no access to that mapping.
  if ("$($r.type)" -ne 'RSE File No' -or -not "$($r.match)") { $skipped++; continue }
  $matter = "$($r.match)"

  $srcPath = ($b.name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
  $dstLeaf = [uri]::EscapeDataString($leaf)
  $dstPath = "$([uri]::EscapeDataString($matter))/Emails/$dstLeaf"

  if (-not $Execute) { Write-Host "would move -> $matter/Emails/$leaf"; $moved++; continue }

  try {
    Invoke-WebRequest -Method Put -Uri "$root/$dstPath`?$sas" -Headers @{
      'x-ms-copy-source' = "$root/$srcPath`?$sas"
      'x-ms-version'     = '2021-08-06'
    } -ErrorAction Stop | Out-Null

    # confirm the destination exists before removing the only other copy
    $head = Invoke-WebRequest -Method Head -Uri "$root/$dstPath`?$sas" -ErrorAction Stop
    if ($head.StatusCode -ne 200) { throw "destination missing after copy" }

    Invoke-WebRequest -Method Delete -Uri "$root/$srcPath`?$sas" -ErrorAction Stop | Out-Null
    $moved++
  } catch {
    Write-Warning "$leaf -> $matter : $($_.Exception.Message)"
    $failed++
    if ($failed -gt 15) { Write-Warning 'too many failures, stopping'; break }
  }
}
Write-Host ("{0}: moved={1} skipped={2} failed={3}" -f $(if($Execute){'EXECUTED'}else{'DRY RUN'}), $moved, $skipped, $failed)

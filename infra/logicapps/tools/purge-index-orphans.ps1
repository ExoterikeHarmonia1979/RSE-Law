#requires -Version 7
<#
Remove search-index documents whose blob no longer exists.

THE BUG THIS FIXES
------------------
The web part builds its download link from metadata_storage_path in the search index. If the
index holds a document whose blob has been deleted, that row looks completely normal in the
results list and fails only when someone clicks it:

    GET  EmlPreviewFunc?path=... -> 404 "The .eml blob was not found."

Which is why the reported symptom is "some emails download fine, others give an error" -
same search, same UI, and no way for the user to tell which is which in advance.

HOW THE ORPHANS GOT THERE
-------------------------
De-duplication deleted ~29k superseded blobs (the old subject-only names, before message-id
tails made them unique) and the Teams retirement deleted more. The data source does carry
NativeBlobSoftDeleteDeletionDetectionPolicy, so in principle the indexer removes documents
for deleted blobs - but ONLY while the blob is still in the soft-deleted state. Storage soft
delete here is 7 days. Once that window closes the blob is purged and the indexer can never
learn it existed, so the document is stranded permanently.

Confirmed on a real document: subject "117.093- status of discovery" is in the index three
times - the old subject-only blob (deleted, 404 on download) and the new tail-named blobs
(present, download fine).

WHY IT DELETES FROM THE INDEX RATHER THAN RESTORING THE BLOB
-----------------------------------------------------------
The deleted blobs were *duplicates*. The message itself is still archived under its
tail-named blob and is still in the index - that is the row that downloads correctly. Removing
the orphan takes away a broken duplicate, not a message. The check below proves this per
document before anything is deleted: an orphan is only purged when the SAME message is still
present under another key.

Dry run unless -Execute.
#>
param(
  [int]$BatchSize = 1000,
  [switch]$RefreshBlobs,
  [switch]$Execute,
  [switch]$PurgeUnbacked   # also remove orphans with no surviving copy (see below)
)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$svc = 'rse-matterssearch'
$idx = 'matters-eml-index'
$api = '2023-11-01'
$base = 'https://samatters.blob.core.windows.net/matters/'

$key = (& $az search admin-key show --service-name $svc -g rg-rse-search-eus --query primaryKey -o tsv)
if (-not $key) { throw "could not read the search admin key" }
$SH = @{ 'api-key' = $key; 'Content-Type' = 'application/json' }
$searchUrl = "https://$svc.search.windows.net/indexes/$idx"

# ── 1. what is actually in storage ────────────────────────────────────────────
$dump = Join-Path $sp 'archive-blobs.txt'
$stale = $RefreshBlobs -or -not (Test-Path $dump) -or
         ((Get-Date) - (Get-Item $dump).LastWriteTime).TotalHours -gt 6
if ($stale) {
  Write-Host "listing the container (a few minutes) ..."
  & $az storage blob list --account-name samatters --container-name matters `
      --num-results "*" --auth-mode login --query "[].name" -o tsv 2>$null | Set-Content $dump
}
$blobNames = @(Get-Content $dump)
# A short listing means the listing failed, not that the archive is empty. Deleting index
# documents on the strength of a truncated listing would wipe the index.
if ($blobNames.Count -lt 100000) {
  throw "container listing returned only $($blobNames.Count) blobs - refusing to decide anything from that"
}
$blobs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($b in $blobNames) { [void]$blobs.Add($b) }
Write-Host "blobs in storage: $($blobs.Count)"

# ── 2. what is in the index ───────────────────────────────────────────────────
# $skip is capped at 100,000 and the index is larger, so this pages by keyset on
# metadata_storage_last_modified (ascending) instead: each page asks for rows at or after the
# last timestamp seen and drops keys already collected. Ties at the same timestamp are handled
# by the 'ge' plus de-duplication, so no document can be skipped.
function Decode([string]$v) {
  if ($v.StartsWith('http')) { return $v }
  $pad = [int]$v[-1] - [int][char]'0'
  if ($pad -lt 0 -or $pad -gt 2) { return $null }
  try {
    $b64 = $v.Substring(0, $v.Length - 1).Replace('-', '+').Replace('_', '/') + ('=' * $pad)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
  } catch { return $null }
}

$total = Invoke-RestMethod -Method Get -Headers $SH -Uri "$searchUrl/docs/`$count?api-version=$api"
Write-Host "documents in index: $total"

$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$orphans = @(); $undecodable = 0

# Partitions, each small enough to page through with $skip.
#
# Not keyset pagination on the timestamp: sorting ascending puts NULLs first, so the cursor
# taken from the last row of page one was empty and produced the filter
# "metadata_storage_last_modified ge " - rejected with "An identifier was expected at
# position 34", which is exactly the length of the field name plus " ge ".
# Nor keyset on the name: attachment names repeat in their thousands (image001.png), and a
# block of identical values larger than a page cannot be advanced past without skipping rows.
function Count-Filter([string]$f) {
  $b = @{ search = '*'; filter = $f; top = 0; count = $true } | ConvertTo-Json
  (Invoke-RestMethod -Method Post -Headers $SH -Uri "$searchUrl/docs/search?api-version=$api" -Body $b).'@odata.count'
}

# Sized against the actual document counts, not a guessed calendar. A month with more than
# the skip cap is split into days, and a day over the cap into hours - one archiving backfill
# put most of the corpus into a single month, and a fixed monthly grid silently scanned only
# 36% of the index while reporting success.
function Expand-Range([datetime]$from, [datetime]$to, [int]$depth) {
  $f = "metadata_storage_last_modified ge {0} and metadata_storage_last_modified lt {1}" -f `
       $from.ToString('yyyy-MM-ddTHH:mm:ssZ'), $to.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $n = Count-Filter $f
  if ($n -eq 0) { return @() }
  if ($n -lt 95000 -or $depth -ge 3) {
    if ($n -ge 95000) { Write-Warning "range $f still holds $n docs at max split depth - some may be missed" }
    return @($f)
  }
  $slices = if ($depth -eq 0) { [math]::Max(1, [int]($to - $from).TotalDays) } else { 24 }
  $step = ($to - $from).TotalMinutes / $slices
  $out = @()
  for ($s = 0; $s -lt $slices; $s++) {
    $out += Expand-Range $from.AddMinutes($step * $s) $from.AddMinutes($step * ($s + 1)) ($depth + 1)
  }
  return $out
}

Write-Host "sizing partitions ..."
$parts = @('metadata_storage_last_modified eq null')
$cur = [datetime]::new(2019, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$end = (Get-Date).ToUniversalTime().AddMonths(2)
while ($cur -lt $end) {
  $next = $cur.AddMonths(1)
  $parts += Expand-Range $cur $next 0
  $cur = $next
}
Write-Host "  $($parts.Count) partitions"

$pi = 0
foreach ($p in $parts) {
  $pi++
  $skip = 0
  while ($true) {
    $body = @{
      search  = '*'
      select  = 'metadata_storage_path,metadata_storage_name'
      filter  = $p
      top     = 1000
      skip    = $skip
      orderby = 'metadata_storage_name asc'
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Method Post -Headers $SH -Uri "$searchUrl/docs/search?api-version=$api" -Body $body
    $n = @($r.value).Count
    if ($n -eq 0) { break }

    foreach ($d in $r.value) {
      if (-not $seen.Add($d.metadata_storage_path)) { continue }
      $url = Decode $d.metadata_storage_path
      if (-not $url -or -not $url.StartsWith($base, 'OrdinalIgnoreCase')) { $undecodable++; continue }
      $name = [uri]::UnescapeDataString($url.Substring($base.Length))
      if (-not $blobs.Contains($name)) {
        $orphans += [pscustomobject]@{ Key = $d.metadata_storage_path; Blob = $name; Name = $d.metadata_storage_name }
      }
    }
    $skip += $n
    if ($n -lt 1000) { break }
    # $skip is capped at 100,000; a partition that big needs splitting further, and silently
    # stopping here would under-report orphans rather than fail loudly.
    if ($skip -ge 100000) { Write-Warning "partition '$p' exceeds the 100k skip cap - split it finer"; break }
  }
  if ($pi % 12 -eq 0) { Write-Host ("  ...{0} partitions, {1} docs, {2} orphans" -f $pi, $seen.Count, $orphans.Count) }
}
Write-Host ("scanned {0} of {1} index documents" -f $seen.Count, $total)
if ($undecodable) { Write-Host "  ($undecodable keys were not decodable to a matters-container blob and were left alone)" }

# ── 3. is the message still archived under another key? ───────────────────────
# The orphans are expected to be de-duplication leftovers, i.e. the same message also exists
# under a tail-named blob. Proving that per document is what makes this safe: if the message
# survives elsewhere, removing the orphan removes a broken duplicate. If it does NOT survive,
# deleting the row would erase the firm's only record that the message existed - so that case
# is reported and skipped unless -PurgeUnbacked is given.
$stems = @{}
foreach ($b in $blobNames) {
  if ($b -match '^(?<m>[^/]+)/Emails/(?<s>.+?)(?: \[[^\]]+\])?\.eml$') {
    $k = ($Matches.m + '|' + $Matches.s).ToLowerInvariant()
    $stems[$k] = $true
  }
}
<#
Before any of that, confirm the blob is really absent.

`az storage blob list` does not round-trip non-ASCII blob names - the repo measured 122 of
6,053 names altered, and HybridVectorSearch.md documents it. A name the listing mangled is
simply missing from the set above, so the document looks orphaned when the blob is fine.

Measured here on the first run of this script: of 1,641 documents the listing called
orphaned, 1,635 had names containing non-ASCII characters, and every one that was checked
individually came back `exists = true`. Deleting on the listing's word would have removed
1,635 working search results - the exact inverse of the bug being fixed.

So the listing is only a candidate filter. Each candidate is then confirmed one at a time
against storage using the name decoded from the INDEX key, which is authoritative.
#>
Write-Host "`nconfirming $($orphans.Count) candidates against storage one by one ..."
$confirmed = @(); $false_ = 0; $i = 0
foreach ($o in $orphans) {
  $i++
  $exists = (& $az storage blob exists --account-name samatters --container-name matters `
               --name $o.Blob --auth-mode login --query exists -o tsv 2>$null)
  if ("$exists" -eq 'true') { $false_++ } else { $confirmed += $o }
  if ($i % 200 -eq 0) { Write-Host ("  checked {0}/{1}; {2} false alarms so far" -f $i, $orphans.Count, $false_) }
}
Write-Host ("  {0} candidates were present after all (listing artefact), {1} confirmed missing" -f $false_, $confirmed.Count)
$orphans = $confirmed

$redundant = @(); $unbacked = @()
foreach ($o in $orphans) {
  $survives = $false
  if ($o.Blob -match '^(?<m>[^/]+)/Emails/(?<s>.+?)(?: \[[^\]]+\])?\.eml$') {
    $survives = $stems.ContainsKey(($Matches.m + '|' + $Matches.s).ToLowerInvariant())
  }
  if ($survives) { $redundant += $o } else { $unbacked += $o }
}

Write-Host "`n=== orphaned index documents ==="
Write-Host ("  {0,6}  total orphans (row shows in search, download returns 404)" -f $orphans.Count)
Write-Host ("  {0,6}  the same message survives under another blob - safe to remove" -f $redundant.Count)
Write-Host ("  {0,6}  NO surviving copy - removing these erases the only record" -f $unbacked.Count)
if ($orphans.Count) { Write-Host ("  {0,6:N2}% of the index" -f (100 * $orphans.Count / [double]$total)) }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$orphans  | Export-Csv (Join-Path $sp "index-orphans-$stamp.csv")  -NoTypeInformation -Encoding utf8
if ($unbacked.Count) {
  $unbacked | Export-Csv (Join-Path $sp "index-unbacked-$stamp.csv") -NoTypeInformation -Encoding utf8
  Write-Host "`n  unbacked examples (NOT deleted unless -PurgeUnbacked):"
  $unbacked | Select-Object -First 8 | ForEach-Object { "    $($_.Blob)" }
}

$targets = if ($PurgeUnbacked) { $orphans } else { $redundant }
Write-Host ("`n{0}: {1} documents would be removed" -f $(if ($Execute) { 'EXECUTING' } else { 'DRY RUN' }), $targets.Count)
if (-not $Execute) { Write-Host "re-run with -Execute to apply."; return }

# ── 4. delete ─────────────────────────────────────────────────────────────────
$done = 0; $failed = 0
for ($i = 0; $i -lt $targets.Count; $i += $BatchSize) {
  $chunk = $targets[$i..([math]::Min($i + $BatchSize - 1, $targets.Count - 1))]
  $payload = @{ value = @($chunk | ForEach-Object {
      @{ '@search.action' = 'delete'; 'metadata_storage_path' = $_.Key } }) } | ConvertTo-Json -Depth 5
  try {
    $resp = Invoke-RestMethod -Method Post -Headers $SH -Uri "$searchUrl/docs/index?api-version=$api" -Body $payload
    $bad = @($resp.value | Where-Object { -not $_.status })
    $done += ($chunk.Count - $bad.Count); $failed += $bad.Count
    if ($bad.Count) { $bad | Select-Object -First 3 | ForEach-Object { Write-Warning "$($_.key): $($_.errorMessage)" } }
  } catch {
    $failed += $chunk.Count
    Write-Warning "batch at $i failed: $($_.Exception.Message)"
  }
  Write-Host ("  removed {0}/{1}" -f $done, $targets.Count)
}
Write-Host "`nEXECUTED: $done removed, $failed failed"
Write-Host "detail: index-orphans-$stamp.csv"

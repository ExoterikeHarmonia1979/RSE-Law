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
for deleted blobs - but ONLY while the blob is still in the soft-deleted state. Once that
window closes the blob is purged and the indexer can never learn it existed, so the document
is stranded permanently.

Blob soft delete is 30 days, raised from 7 on 2026-09-08 for the duplicate cleanup (container
soft delete is a separate 7 and does not apply). Against an indexer that runs hourly that is
an enormous margin, so the stranding above is now the exception rather than the rule: measured
2026-09-09, 748 of 749 confirmed soft-deleted blobs had left the index within one indexer run,
while 250 of 250 deleted after that run were still present - the same lookup over both, which
is what makes the first number mean something. This script is therefore no longer needed for
the bulk of a cleanup.

What it IS still needed for: blobs whose name contains a '/' (a slash inside the subject, so
the path is <matter>/Emails/<part1>/<part2>.eml). Those shed unreliably - 17 of 75 were still
indexed after two consecutive indexer runs, against 0 of 100 for ordinary names, all confirmed
404 in storage. About 377 of the 58,779 blobs in the current cleanup have that shape, so on
the order of 85 stranded documents. The mechanism is not understood.

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
  [switch]$PurgeUnbacked,  # also remove orphans with no surviving copy (see below)
  # Offline negative controls. Before every credential and network call, so it runs anywhere.
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

<#
The identity of a MESSAGE, as opposed to the identity of a blob: matter plus cleaned subject,
with the trailing "[id]" dropped so every copy of one message collapses to one key. Used both
to build the set of surviving messages and to ask whether an orphan's message survives.

Both extensions count, and that is the whole point. The archive holds the same message as a
`.eml` written by the live pipeline and as a `.msg` produced by the ingest, and the de-duplication
treats those as one message - every group has exactly one survivor by construction. Matching only
`.eml` therefore does not merely miss a few: it declares every `.msg` orphan "unbacked", the
class this script refuses to delete. Replayed against the current cleanup that is 18,217 of
58,779 blobs (37% including the .eml misses) reported as having no surviving copy when they all
have one. The temptation that creates is the dangerous part - reaching for -PurgeUnbacked to
force them through, which is exactly the check that makes deleting safe at all.
#>
function Get-MessageStem([string]$Blob) {
  if ($Blob -match '^(?<m>[^/]+)/Emails/(?<s>.+?)(?: \[[^\]]+\])?\.(?:eml|msg)$') {
    <#
    The subject is normalised because the two write paths sanitise it differently, so one
    message is stored under names that are not equal as strings: "RE: Claim No. 23-7025944"
    beside "RE_ Claim No. 23-7025944", "2033962/FW: Summons" beside "2033962 _ FW_ Summons",
    and runs of spaces preserved by one path and collapsed by the other. Comparing raw, 8,505
    of the deleted blobs in the current cleanup do not match their own group's survivor.
    Normalising cuts that to 2,618.

    Only characters that are illegal or awkward in a path are folded, plus whitespace and the
    underscore they get replaced by. That is undoing sanitisation, not discarding meaning:
    "Invoice 49728" and "Invoice 49729" stay different, and there is a control for it.

    The cost is measured and small. Distinct keys fall 18,581 -> 18,047, and keys shared by
    more than one group rise 5,939 -> 6,021. That second number is the one that matters,
    because a shared key lets one message stand in as the survivor of another - but note it
    is 5,939 BEFORE this change, covering 25,579 of 38,221 groups. Matter-plus-subject was
    always a weak identity; this makes it 616 groups weaker while fixing 5,887 misclassified
    blobs.

    The real fix is to key on the message identity rather than the subject, and it is not
    available here: the k-token is minted from the message bytes, and an orphan is by
    definition a blob that no longer exists to be read. Nor can it be taken from the
    surviving name - 0 of the 38,221 survivors in this cleanup carry a k-token, because the
    keep-rule prefers the legacy copy and legacy names carry a mailbox-id tail instead.
    #>
    $s = ($Matches.s -replace '[:/\\*?"<>|]', '_') -replace '[\s_]+', ' '
    return ($Matches.m + '|' + $s.Trim()).ToLowerInvariant()
  }
  return $null
}

if ($SelfTest) {
  $fail = @()
  function Check($name, $got, $want) {
    if ($got -eq $want) { Write-Host "  ok   $name" }
    else { Write-Host "  FAIL $name (got '$got', wanted '$want')"; $script:fail += $name }
  }
  Write-Host 'message stem:'
  Check 'legacy .eml with tail' (Get-MessageStem '100.079/Emails/CMC re POS [QYbmEur862QBAAQvGD4UAAA].eml') '100.079|cmc re pos'
  Check 'k-token .eml'          (Get-MessageStem '100.079/Emails/CMC re POS [k073646675726cdd6541af1].eml') '100.079|cmc re pos'
  # The ingest writes .msg. Before this was fixed these returned nothing, so every .msg orphan
  # was classified as having no surviving copy.
  Check 'k-token .msg'          (Get-MessageStem '100.079/Emails/CMC re POS [k073646675726cdd6541af1].msg') '100.079|cmc re pos'
  Check 'legacy .msg with tail' (Get-MessageStem '100.079/Emails/CMC re POS [QYbmEur862QBAAQvGD4UAAA].msg') '100.079|cmc re pos'
  # A .msg and a .eml of one message must collapse to the SAME key, or the survivor is not found.
  Check 'msg and eml agree' `
    ((Get-MessageStem '120.033/Emails/FW_ INVOICE [k000e8ee8b76730fb638222].msg') -eq
     (Get-MessageStem '120.033/Emails/FW_ INVOICE [TKHIWU4VNG_RAALFKSWRAAA].eml')) $true
  Check 'no bracket suffix'     (Get-MessageStem '98.060/Emails/demand for expert exchange.eml') '98.060|demand for expert exchange'
  # The two write paths sanitise subjects differently, so the SAME message is stored under
  # names that differ only in punctuation and spacing. Each pair below is one real message.
  Check 'colon and underscore agree' `
    ((Get-MessageStem '100.202/Emails/RE: Claim No. 23-7025944; Maldonado.eml') -eq
     (Get-MessageStem '100.202/Emails/RE_ Claim No. 23-7025944; Maldonado [TKHIWU4VNG_RAAL9PP9KAAA].eml')) $true
  Check 'slash and underscore agree' `
    ((Get-MessageStem '140.043/Emails/Re: CIG claim 2033962/FW: Summons for C&S.eml') -eq
     (Get-MessageStem '140.043/Emails/Re_ CIG claim 2033962 _ FW_ Summons for C&S [TKHIWU4VNG_RAAMUG].eml')) $true
  Check 'repeated whitespace collapses' `
    ((Get-MessageStem '100.222/Emails/Re_ Morales v Blue Hill RSE                  File #100.222 [k00668b0aa67eb0beadd].eml') -eq
     (Get-MessageStem '100.222/Emails/Re_ Morales v Blue Hill RSE File #100.222 [TKHIWU4VNG_RAAM].eml')) $true
  # Normalising must not merge two genuinely different subjects in one matter.
  Check 'different subjects stay apart' `
    ((Get-MessageStem '117.001/Emails/RE_ Invoice 49728.eml') -eq
     (Get-MessageStem '117.001/Emails/RE_ Invoice 49729.eml')) $false
  # Attachments live under a different path and are not messages; matching one would let an
  # attachment stand in as the surviving copy of a message that is actually gone.
  Check 'attachment is not a message' (Get-MessageStem '100.079/Emails/Attachments/k073/2026-07-30 MO.pdf') $null
  Check 'other extension ignored'     (Get-MessageStem '100.079/Emails/CMC re POS [k073].pdf')              $null
  Write-Host ''
  if ($fail.Count) { Write-Host "$($fail.Count) control(s) misbehaved: $($fail -join ', ')"; exit 1 }
  Write-Host 'all message-stem controls behaved as specified.'
  exit 0
}
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
  $k = Get-MessageStem $b
  if ($k) { $stems[$k] = $true }
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
Write-Host "`nconfirming $($orphans.Count) candidates against storage ..."
$stoken = (& $az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
if (-not $stoken) { throw "could not get a storage token to confirm candidates" }

# A ranged/HEAD request per candidate, in parallel. `az storage blob exists` would be a
# process launch each time - hours for this many - and the whole point of this step is that it
# has to run every time, not be skipped because it is slow.
#
# x-ms-version is REQUIRED for bearer auth. Omitting it returns 403, and a 403 counted as
# "missing" would delete live documents; this repo has made that exact mistake before, when a
# dropped x-ms-version turned 195,815 auth failures into "no Message-ID".
$results = $orphans | ForEach-Object -ThrottleLimit 24 -Parallel {
  $u = 'https://samatters.blob.core.windows.net/matters/' +
       (($_.Blob -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
  $h = @{ Authorization = "Bearer $using:stoken"; 'x-ms-version' = '2021-12-02' }
  $status = 0
  for ($try = 1; $try -le 3; $try++) {
    try { $status = (Invoke-WebRequest -Uri $u -Method Head -Headers $h -SkipHttpErrorCheck).StatusCode; break }
    catch { Start-Sleep -Milliseconds (200 * $try) }
  }
  [pscustomobject]@{ Key = $_.Key; Blob = $_.Blob; Name = $_.Name; Status = $status }
}

$present = @($results | Where-Object Status -eq 200)
$missing = @($results | Where-Object Status -eq 404)
$unknown = @($results | Where-Object { $_.Status -ne 200 -and $_.Status -ne 404 })

Write-Host ("  {0,6}  present after all - the blob listing lost the name" -f $present.Count)
Write-Host ("  {0,6}  confirmed missing" -f $missing.Count)
if ($unknown.Count) {
  Write-Host ("  {0,6}  INDETERMINATE (auth/throttle) - excluded, never treated as missing" -f $unknown.Count)
  $unknown | Group-Object Status | ForEach-Object { "          status $($_.Name): $($_.Count)" }
  # A large indeterminate share means the check itself is failing, and acting on the rest
  # would be acting on partial evidence.
  if ($unknown.Count -gt 0.05 * $results.Count) {
    throw "too many indeterminate results ($($unknown.Count) of $($results.Count)) - refusing to propose deletions"
  }
}
$orphans = @($missing | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Blob = $_.Blob; Name = $_.Name } })

$redundant = @(); $unbacked = @()
foreach ($o in $orphans) {
  $survives = $false
  $k = Get-MessageStem $o.Blob
  if ($k) { $survives = $stems.ContainsKey($k) }
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

<#
Save the message itself before deleting the row that points at it.

For an unbacked orphan the blob is already gone, so the index document is the last trace of
the message anywhere - and the indexer put the extracted body text into `content` along with
the sender, recipients and date. Deleting the row without keeping that discards evidence that
a message existed, which for a law firm's correspondence archive is not a reversible mistake.

So the full document is written out first, as JSON, one file per run. Nothing is deleted
until that file is on disk. Same reasoning as the manifest in delete-teams.ps1.
#>
if ($Execute -and $targets.Count) {
  $manifest = Join-Path $sp "purged-documents-$stamp.json"
  $saved = @()
  foreach ($t in $targets) {
    try {
      $doc = Invoke-RestMethod -Method Get -Headers $SH `
               -Uri "$searchUrl/docs('$([uri]::EscapeDataString($t.Key))')?api-version=$api"
      $saved += [pscustomobject]@{
        Blob        = $t.Blob
        Key         = $t.Key
        Subject     = "$($doc.metadata_subject)"
        From        = "$($doc.metadata_message_from)"
        To          = "$($doc.metadata_message_to)"
        Cc          = "$($doc.metadata_message_cc)"
        SentDate    = "$($doc.sent_date)"
        Attachments = @($doc.attachment_names)
        Content     = "$($doc.content)"
      }
    } catch {
      Write-Warning "could not read $($t.Blob) before deleting: $($_.Exception.Message)"
    }
  }
  if ($saved.Count -ne $targets.Count) {
    throw "only captured $($saved.Count) of $($targets.Count) documents - refusing to delete what has not been saved"
  }
  $saved | ConvertTo-Json -Depth 6 | Set-Content $manifest -Encoding utf8
  Write-Host "saved the full text of $($saved.Count) documents to $(Split-Path $manifest -Leaf) before deleting"
}

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

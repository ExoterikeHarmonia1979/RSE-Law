#requires -Version 7
<#
Build a Message-ID -> blob index over the archived .eml corpus.

WHY THIS EXISTS
---------------
The RFC 5322 Message-ID is the only identity a message keeps when it moves between mailbox
stores. Everything else the archive keys on is store-scoped: blob names end in the last 24
chars of the GRAPH message id, and the same message carries a different Graph id in the
In-Place Archive than it did in the primary mailbox.

That matters because the retention policy ("Matters Archive - 6 Months") is steadily moving
mail into the archive that was ALREADY blob-archived from the primary. Measured on matter
120.057: sampling 200 archive items against 138 blob headers found 9 messages present in
both - and since both samples covered a fraction of each side, the true overlap is far
larger. Ingesting the archive without dedup would write those as NEW blobs alongside the
originals: silent duplicates, invisible in run history, the same shape as the 28,915
redundant blobs this project has already had to clean up once.

So before any archive ingest, we need to know which Message-IDs are already archived. That is
this index.

It is also useful beyond the ingest: it is the first identity map of the corpus that does not
depend on blob naming, so it can answer "is this message archived?" for any source.

HOW
---
A ranged GET per blob reads just the header block and pulls the Message-ID out. Full downloads
would move terabytes; the headers are the first few KB.

FAILURES ARE RECORDED AS FAILURES
---------------------------------
Every serious bug in this project has been a failure recorded as data:
  - a dropped x-ms-version turned 195,815 auth failures into "no Message-ID"
  - Graph throttling turned 11,197 reads into "unmatched mail"
  - and this very check, two hours ago, reported "no overlap - safe to ingest" because
    Invoke-WebRequest returns Content as a string in PowerShell 7 and the resulting exception
    was swallowed by a bare catch

So a blob that cannot be read is written to the index with its HTTP status and NEVER as
"no Message-ID". The run aborts if too many reads fail, rather than emitting a confident
index built on holes.

RESUMABLE
---------
Results are appended as they are produced. Re-running skips blobs already present, so a run
interrupted at hour three resumes rather than restarts. The storage token is refreshed
between chunks because it expires in about an hour and a stale token returns 401 - which,
uncaught, is exactly the failure-as-data trap above.
#>
param(
  [int]$ChunkSize   = 2000,     # blobs per chunk; token refreshed between chunks
  [int]$Parallel    = 24,
  [int]$HeadBytes   = 16384,    # first read; 8 KB missed ~8% in testing
  [int]$RetryBytes  = 131072,   # second read for blobs whose headers ran past HeadBytes
  [double]$MaxFailureRate = 0.02,
  [switch]$RefreshBlobs,
  [switch]$Restart
)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$out = Join-Path $sp 'messageid-index.tsv'
$base = 'https://samatters.blob.core.windows.net/matters/'

<#
--- where the blob names come from ---------------------------------------------------------

NOT from `az storage blob list`. That command does not round-trip non-ASCII blob names: a
subject containing a section sign arrives as "CCP  1005" instead of "CCP § 1005", and the
resulting name 404s because no such blob exists. A first run of this script hit exactly that -
87 failures in 3,900 reads, every one a 404 on a mangled name, and every one a blob that is
actually present and readable.

The search index holds the truth. Its key, metadata_storage_path, is the real blob URL
base64-encoded by the indexer, so decoding it gives a name that is correct by construction -
including every accent, dash and section sign. It is also the same name the web part builds
its download links from, so an index built on it matches what users actually click.

Falls back to the blob listing only if the search index is unavailable, and says so loudly,
because that path is known to be lossy.
#>
$names = @()
$k = (& $az search admin-key show --service-name rse-matterssearch -g rg-rse-search-eus --query primaryKey -o tsv 2>$null)
if ($k) {
  $SH = @{ 'api-key' = $k; 'Content-Type' = 'application/json' }
  $u  = "https://rse-matterssearch.search.windows.net/indexes/matters-eml-index/docs/search?api-version=2023-11-01"
  Write-Host "reading blob names from the search index ..."

<#
  $skip caps at 100,000, so the index has to be read in partitions - but a FIXED monthly grid
  does not work here. Almost every blob was written during the archive recovery, so one month
  holds most of the corpus; that partition silently truncates at the cap and the run reports
  success having read a fraction of the index. It did exactly that on the first attempt:
  47,139 .eml recovered against 255,129 in the container.

  An index that is quietly missing 80% of the corpus is worse than none, because the ingest
  would dedup against it and duplicate everything it failed to list.

  So partitions are sized by actual document count and split - months, then days, then hours -
  until each fits under the cap.
#>
  function Count-Filter([string]$flt) {
    $b = @{ search='*'; filter=$flt; top=0; count=$true } | ConvertTo-Json
    (Invoke-RestMethod -Method Post -Headers $SH -Uri $u -Body $b).'@odata.count'
  }
  function Expand-Range([datetime]$from, [datetime]$to, [int]$depth) {
    $flt = "metadata_storage_last_modified ge {0} and metadata_storage_last_modified lt {1}" -f `
           $from.ToString('yyyy-MM-ddTHH:mm:ssZ'), $to.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $n = Count-Filter $flt
    if ($n -eq 0) { return @() }
    if ($n -lt 95000 -or $depth -ge 3) {
      if ($n -ge 95000) { Write-Warning "range holds $n docs at max split depth - may truncate" }
      return @($flt)
    }
    $slices = if ($depth -eq 0) { [math]::Max(1, [int]($to - $from).TotalDays) } else { 24 }
    $step = ($to - $from).TotalMinutes / $slices
    $acc = @()
    for ($s = 0; $s -lt $slices; $s++) {
      $acc += Expand-Range $from.AddMinutes($step*$s) $from.AddMinutes($step*($s+1)) ($depth+1)
    }
    return $acc
  }

  Write-Host "  sizing partitions ..."
  $cur = [datetime]::new(2019,1,1,0,0,0,[DateTimeKind]::Utc)
  $end = (Get-Date).ToUniversalTime().AddMonths(2)
  $parts = @('metadata_storage_last_modified eq null')
  while ($cur -lt $end) {
    $next = $cur.AddMonths(1)
    $parts += Expand-Range $cur $next 0
    $cur = $next
  }
  Write-Host "  $($parts.Count) partitions"
  $seenKey = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($p in $parts) {
    $skip = 0
    while ($true) {
      $body = @{ search='*'; select='metadata_storage_path'; filter=$p; top=1000; skip=$skip
                 orderby='metadata_storage_name asc' } | ConvertTo-Json
      $r = Invoke-RestMethod -Method Post -Headers $SH -Uri $u -Body $body
      $n = @($r.value).Count
      if ($n -eq 0) { break }
      foreach ($d in $r.value) {
        $v = $d.metadata_storage_path
        if (-not $seenKey.Add($v)) { continue }
        try {
          $pad = [int]$v[-1] - 48
          $b64 = $v.Substring(0, $v.Length-1).Replace('-','+').Replace('_','/') + ('=' * $pad)
          $url = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
          if ($url.StartsWith($base, 'OrdinalIgnoreCase')) {
            $names += [uri]::UnescapeDataString($url.Substring($base.Length))
          }
        } catch { }
      }
      $skip += $n
      if ($n -lt 1000 -or $skip -ge 100000) { break }
    }
  }
  Write-Host "  $($names.Count) blob names from the index"

  # Assert the read was complete. The index knows how many documents it holds, so a shortfall
  # means partitions truncated - and a silently short name list is the one failure mode that
  # would make this whole index dangerous rather than merely incomplete.
  $total = Invoke-RestMethod -Method Get -Headers $SH `
             -Uri "https://rse-matterssearch.search.windows.net/indexes/matters-eml-index/docs/`$count?api-version=2023-11-01"
  Write-Host "  index reports $total documents; $($seenKey.Count) keys were read"
  if ($seenKey.Count -lt $total * 0.98) {
    throw ("only read {0} of {1} index documents - partitions truncated. Refusing to build an index that would under-report what is archived." -f $seenKey.Count, $total)
  }
}

if ($names.Count -lt 100000) {
  Write-Warning "search index gave only $($names.Count) names - falling back to the blob listing, which mangles non-ASCII names"
  $dump = Join-Path $sp 'archive-blobs.txt'
  if ($RefreshBlobs -or -not (Test-Path $dump) -or ((Get-Date) - (Get-Item $dump).LastWriteTime).TotalHours -gt 12) {
    Write-Host "listing the container (a few minutes) ..."
    & $az storage blob list --account-name samatters --container-name matters `
        --num-results "*" --auth-mode login --query "[].name" -o tsv 2>$null | Set-Content $dump
  }
  $all = @(Get-Content $dump)
  if ($all.Count -lt 100000) { throw "container listing returned only $($all.Count) blobs - refusing to build an index from that" }
  $names = $all
}

$eml = @($names | Where-Object { $_ -like '*.eml' })
Write-Host "eml blobs: $($eml.Count)"

# --- resume -------------------------------------------------------------------------------
if ($Restart) { Remove-Item $out -ErrorAction SilentlyContinue }
$done = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (Test-Path $out) {
  foreach ($line in [IO.File]::ReadLines($out)) {
    $t = $line.Split("`t")
    if ($t.Count -ge 1 -and $t[0]) { [void]$done.Add($t[0]) }
  }
  Write-Host "resuming: $($done.Count) blobs already indexed"
} else {
  "blob`tmessageId`tstatus" | Set-Content $out -Encoding utf8
}
$todo = @($eml | Where-Object { -not $done.Contains($_) })
Write-Host "to do: $($todo.Count)"
if (-not $todo.Count) { Write-Host "nothing to do."; }

# --- work ---------------------------------------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
$okTotal = 0; $noIdTotal = 0; $failTotal = 0; $processed = 0

for ($i = 0; $i -lt $todo.Count; $i += $ChunkSize) {
  $chunk = $todo[$i..([math]::Min($i + $ChunkSize - 1, $todo.Count - 1))]

  # Fresh token per chunk. A storage bearer token lasts ~1 hour; this run is longer than that,
  # and an expired token returns 401 on every remaining blob.
  $stok = (& $az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
  if (-not $stok) { throw "could not acquire a storage token" }

  $results = $chunk | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    # $using: is bound to locals FIRST. It does not resolve inside a nested function, and it
    # cannot carry method calls - both are quiet failures rather than errors.
    $name  = $_
    $tok   = $using:stok
    $head  = $using:HeadBytes
    $retry = $using:RetryBytes
    $url   = $using:base + (($name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')

    function Read-Head([int]$bytes) {
      $req = @{ Authorization = "Bearer $tok"; 'x-ms-version' = '2021-12-02'; Range = "bytes=0-$($bytes-1)" }
      for ($try = 1; $try -le 3; $try++) {
        try {
          $r = Invoke-WebRequest -Uri $url -Headers $req -SkipHttpErrorCheck
          $code = [int]$r.StatusCode
          if ($code -in 200, 206) {
            # PowerShell 7 already decodes Content to a string; calling GetString on it throws.
            $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::ASCII.GetString($r.Content) } else { "$($r.Content)" }
            return @{ Code = $code; Text = $text }
          }
          if ($code -in 429, 500, 503) { Start-Sleep -Milliseconds (400 * $try); continue }
          return @{ Code = $code; Text = '' }
        } catch { Start-Sleep -Milliseconds (400 * $try) }
      }
      return @{ Code = -1; Text = '' }
    }

    $res = Read-Head $head
    $mid = $null
    if ($res.Text -match '(?im)^Message-ID:\s*<?([^>\r\n]+)>?') { $mid = $Matches[1].Trim() }

    # Headers can run past the first read - long Received chains, big DKIM signatures.
    # Read further before concluding the message has no Message-ID at all.
    if (-not $mid -and $res.Code -in 200, 206) {
      $res2 = Read-Head $retry
      if ($res2.Text -match '(?im)^Message-ID:\s*<?([^>\r\n]+)>?') { $mid = $Matches[1].Trim() }
      if ($res2.Code -notin 200, 206) { $res = $res2 }
    }

    if ($mid)                          { "$name`t$mid`tok" }
    elseif ($res.Code -in 200, 206)    { "$name`t`tno-message-id" }
    else                               { "$name`t`thttp-$($res.Code)" }   # a FAILURE, not an absence
  }

  Add-Content -Path $out -Value $results -Encoding utf8

  foreach ($r in $results) {
    $s = $r.Split("`t")[2]
    switch ($s) {
      'ok'            { $okTotal++ }
      'no-message-id' { $noIdTotal++ }
      default         { $failTotal++ }
    }
  }
  $processed += $chunk.Count

  $rate = if ($sw.Elapsed.TotalMinutes -gt 0) { $processed / $sw.Elapsed.TotalMinutes } else { 0 }
  $left = if ($rate -gt 0) { ($todo.Count - $processed) / $rate } else { 0 }
  Write-Host ("  {0,7}/{1}  ok={2} noid={3} fail={4}  {5:N0}/min  ~{6:N0} min left" -f `
    $processed, $todo.Count, $okTotal, $noIdTotal, $failTotal, $rate, $left)

  # An index full of holes is worse than no index: it would silently under-report what is
  # already archived, and the ingest would duplicate exactly those messages.
  if ($processed -ge 2000 -and ($failTotal / [double]$processed) -gt $MaxFailureRate) {
    throw ("aborting: {0:P1} of reads failed ({1} of {2}). Fix the cause before trusting this index." -f `
           ($failTotal / [double]$processed), $failTotal, $processed)
  }
}

$sw.Stop()
Write-Host "`n=== done in {0:N1} min ===" -f $sw.Elapsed.TotalMinutes
Write-Host ("  {0,8}  Message-IDs recovered" -f $okTotal)
Write-Host ("  {0,8}  genuinely had none" -f $noIdTotal)
Write-Host ("  {0,8}  could not be read (recorded with status, NOT as absent)" -f $failTotal)
Write-Host "  index: $out"


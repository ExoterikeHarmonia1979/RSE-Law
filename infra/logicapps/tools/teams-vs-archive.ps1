#requires -Version 7
<#
Which of the 12,206 Teams emails are NOT already in the blob archive?

Compares by RFC 5322 Message-ID, the only identity that survives being copied - the same
test that caught 1,427 wrongly-classified blobs earlier. Filenames and subjects are not
identity: the same message appears under several names, and different messages share subjects.

Three phases:
  1. list the archive fresh (28,915 blobs were just deleted, so any cached listing is wrong)
  2. read Message-ID from every archive matter email      (~194k ranged reads)
  3. read Message-ID from every Teams .eml                (12,206 ranged reads via Graph)

Only the first 256 KB of each file is fetched - headers live there. Tokens are refreshed per
chunk because they expire in about an hour and this outlives that.

Read-only. Writes teams-only.json (the gap) and teams-matched.txt.
#>
param([int]$Parallel = 24, [int]$GraphParallel = 6, [int]$ChunkSize = 6000, [switch]$SkipRelist)
$ErrorActionPreference = 'Stop'
$sp    = $PSScriptRoot
$az    = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$acct  = 'https://samatters.blob.core.windows.net/matters/'
$dump  = Join-Path $sp 'allblobs3.txt'

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(60)

# $Mode is a string, not a script block: ForEach-Object -Parallel rejects script-block
# $using: variables outright ("Passed-in script block variables are not supported"), so the
# URL has to be built inside the parallel body.
function Read-Ids([string[]]$items, [string]$resource, [string]$Mode) {
  $ids = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
  $chunks = [math]::Ceiling($items.Count / $ChunkSize)
  for ($i = 0; $i -lt $chunks; $i++) {
    $slice = $items[($i*$ChunkSize)..([math]::Min(($i+1)*$ChunkSize-1, $items.Count-1))]
    $tok = (& $az account get-access-token --resource $resource --query accessToken -o tsv)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $limit = if ($Mode -eq 'graph') { $GraphParallel } else { $Parallel }
    $slice | ForEach-Object -ThrottleLimit $limit -Parallel {
      $key = $_; $cl = $using:client; $tk = $using:tok; $dict = $using:ids
      $url = if ($using:Mode -eq 'graph') {
        $p = $key -split '\|'
        "https://graph.microsoft.com/v1.0/groups/$($p[0])/drive/items/$($p[1])/content"
      } else {
        $using:acct + (($key -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
      }
      # Graph throttles hard: at 24-way parallelism 11,197 of 12,206 reads came back 429
      # while a 3-file smoke test passed cleanly. Retry with backoff, honouring Retry-After.
      $attempt = 0
      while ($true) {
      $attempt++
      try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
        $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $tk)
        # REQUIRED for Bearer auth against blob storage. Without it every request returns 403
        # "Authentication scheme Bearer is not supported in this version", and because a 403
        # body carries no Message-ID, 195,815 auth failures were recorded as "unreadable" and
        # looked like real data. Lost in a refactor from the working script; never drop it.
        $req.Headers.Add('x-ms-version','2021-08-06')
        $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 262143)
        $resp  = $cl.SendAsync($req).GetAwaiter().GetResult()
        $code  = [int]$resp.StatusCode
        if ($code -in @(429,503,504,500) -and $attempt -lt 6) {
          $wait = 2 * $attempt
          if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $wait = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds }
          $resp.Dispose(); $req.Dispose()
          Start-Sleep -Seconds ([math]::Min($wait, 30))
          continue
        }
        if (-not $resp.IsSuccessStatusCode) {
          # Record the STATUS. An empty string here is indistinguishable from "no header",
          # which is what let a total auth failure masquerade as a finding and would have
          # classified all 12,206 Teams emails as missing from the archive.
          [void]$dict.TryAdd($key, "!HTTP $code")
          $resp.Dispose(); $req.Dispose(); break
        }
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $m = [regex]::Match([Text.Encoding]::ASCII.GetString($bytes), '(?im)^Message-ID\s*:\s*<([^>]+)>')
        [void]$dict.TryAdd($key, $(if ($m.Success) { $m.Groups[1].Value } else { '' }))
        $resp.Dispose(); $req.Dispose()
        break
      } catch {
        if ($attempt -ge 6) { [void]$dict.TryAdd($key, '!EX'); break }
        Start-Sleep -Seconds (2 * $attempt)
      }
      }
    }
    $sw.Stop()
    Write-Host ("    chunk {0}/{1}: {2} in {3}s" -f ($i+1), $chunks, $slice.Count, [math]::Round($sw.Elapsed.TotalSeconds))
  }
  $ids
}

# ---------------------------------------------------------------- 1. archive listing
if ($SkipRelist -and (Test-Path $dump)) {
  Write-Host "reusing $dump"
} else {
  Write-Host "1. listing the archive fresh ..."
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $az storage blob list --account-name samatters --container-name matters `
      --num-results "*" --auth-mode login --query "[].name" -o tsv 2>$null | Set-Content $dump
  $sw.Stop(); Write-Host ("   listed in {0} min" -f [math]::Round($sw.Elapsed.TotalMinutes,1))
}
$archive = @(Get-Content $dump | Where-Object { $_ -like '*/Emails/*.eml' -and $_ -notlike '*/Emails/Attachments/*' })
Write-Host "   archive matter emails: $($archive.Count)"

# ---------------------------------------------------------------- 2. archive Message-IDs
# Cached: this phase costs ~30 minutes, and re-running it because the Teams phase failed
# wastes half an hour for nothing. The archive only grows, so a stale cache understates
# matches - which is the safe direction (it can only over-report the gap, never hide it).
$cache = Join-Path $sp 'archive-msgids.txt'
$archiveSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$blank = 0; $httpFail = 0
if (Test-Path $cache) {
  foreach ($l in (Get-Content $cache)) { if ("$l".Trim()) { [void]$archiveSet.Add("$l".Trim()) } }
  Write-Host "2. reusing cached archive Message-IDs: $($archiveSet.Count)"
} else {
  Write-Host "2. reading archive Message-IDs ..."
  $archiveIds = Read-Ids $archive 'https://storage.azure.com' 'blob'
  foreach ($v in $archiveIds.Values) {
    if ($v -like '!*')  { $httpFail++ }
    elseif ($v)         { [void]$archiveSet.Add($v) }
    else                { $blank++ }
  }
  $archiveSet | Set-Content $cache
}
Write-Host "   distinct Message-IDs in archive: $($archiveSet.Count)   no header: $blank   request failed: $httpFail"
# A missing or thin archive set INVERTS the comparison - every Teams email would look absent
# and the upload would duplicate the entire corpus. That is exactly what the dropped
# x-ms-version header produced: 195,815 failures reported as 0 Message-IDs. Refuse to emit a
# plausible-looking wrong answer.
if ($archiveSet.Count -lt ($archive.Count * 0.5)) {
  throw "only $($archiveSet.Count) Message-IDs from $($archive.Count) archive blobs ($httpFail request failures) - refusing to compare against a broken baseline"
}

# ---------------------------------------------------------------- 3. Teams Message-IDs
Write-Host "3. reading Teams Message-IDs ..."
$inv = Get-Content (Join-Path $sp 'teams-inventory.json') -Raw | ConvertFrom-Json
$map = @{}
foreach ($f in $inv) { $map["$($f.GroupId)|$($f.ItemId)"] = $f }
$keys = @($map.Keys)
$teamIds = Read-Ids $keys 'https://graph.microsoft.com' 'graph'

# ---------------------------------------------------------------- 4. compare
$only = @(); $matched = 0; $unreadable = 0; $teamFail = 0
foreach ($k in $keys) {
  $id = $teamIds[$k]
  # a '!HTTP 403' marker is truthy: without this test it would be treated as a Message-ID,
  # fail to match, and be counted as "only in Teams" - uploading a file we never read
  if ($id -like '!*') { $teamFail++; continue }
  if (-not $id) { $unreadable++; continue }
  if ($archiveSet.Contains($id)) { $matched++ }
  else { $f = $map[$k]; $only += [pscustomobject]@{ Matter=$f.Matter; Name=$f.Name; GroupId=$f.GroupId; ItemId=$f.ItemId; Size=$f.Size; MessageId=$id } }
}
if ($teamFail -gt ($keys.Count * 0.1)) {
  throw "$teamFail of $($keys.Count) Teams reads failed - refusing to emit a gap list built on failed reads"
}
$only | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $sp 'teams-only.json') -Encoding utf8

Write-Host ""
Write-Host "Teams emails            : $($keys.Count)"
Write-Host "already in the archive  : $matched"
Write-Host "ONLY in Teams           : $($only.Count)"
Write-Host "Message-ID unreadable   : $unreadable"
Write-Host "read failures (excluded) : $teamFail"
if ($only.Count) {
  Write-Host ""
  Write-Host "matters with the most Teams-only mail:"
  $only | Group-Object Matter | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { "  {0,5}  {1}" -f $_.Count, $_.Name }
}
$client.Dispose()





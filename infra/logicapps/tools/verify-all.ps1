#requires -Version 7
<#
Verify EVERY "superseded" blob by Message-ID, and emit only the proven-redundant ones.

Subject-stem matching is too coarse to delete on: a 30-blob sample found 2 old blobs whose
Message-ID appears in no new copy - different messages from the same thread, where the old
blob is the only surviving record. At that rate roughly 2,000 of 30,342 would have been real
correspondence destroyed.

RFC 5322 Message-ID is assigned by the originating mail system and travels unchanged in every
copy, so equality proves the same message exists elsewhere in the archive.

Speed: only the first 256 KB of each blob is fetched (headers live there) via a ranged GET on
the storage REST API, in parallel. Per-blob `az storage blob download` would be many hours.
The token is refreshed per chunk because it expires in about an hour and this job outlives that.

Read-only. Writes two lists; deletes nothing.
#>
param([int]$Parallel = 16, [int]$ChunkSize = 6000)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$acct = 'https://samatters.blob.core.windows.net/matters/'

$all = Get-Content (Join-Path $sp 'allblobs2.txt')
$sup = Get-Content (Join-Path $sp 'superseded.txt')
Write-Host "superseded candidates: $($sup.Count)"

# (matter,stem) -> new-format blobs
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

# every blob whose Message-ID we need: the old ones plus their candidates
$pairs = @()
$need  = [System.Collections.Generic.HashSet[string]]::new()
foreach ($old in $sup) {
  $parts = $old -split '/'; $matter = $parts[0]
  $stem = ($parts[-1] -replace '\.eml$','').Trim(); if ($stem.Length -gt 150) { $stem = $stem.Substring(0,150).Trim() }
  $c = $newIx["$matter|$stem"]
  if (-not $c) { continue }
  $pairs += [pscustomobject]@{ Old = $old; New = $c }
  [void]$need.Add($old); foreach ($x in $c) { [void]$need.Add($x) }
}
$needList = @($need)
Write-Host "blobs to read: $($needList.Count)  (pairs: $($pairs.Count))"

$ids = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
# One shared HttpClient. Invoke-WebRequest will not take Range as a plain header in PS7 - it
# silently fell back to fetching whole multi-megabyte blobs - and a client per request would
# exhaust sockets over ~70k reads. HttpClient is thread-safe for concurrent sends.
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(60)
$chunks = [math]::Ceiling($needList.Count / $ChunkSize)
for ($i = 0; $i -lt $chunks; $i++) {
  $slice = $needList[($i*$ChunkSize)..([math]::Min(($i+1)*$ChunkSize-1, $needList.Count-1))]
  $tok = (& $az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $slice | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    $name = $_
    $url  = $using:acct + (($name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $dict = $using:ids
    $cl   = $using:client
    $tk   = $using:tok
    try {
      $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
      $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $tk)
      $req.Headers.Add('x-ms-version','2021-08-06')
      $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 262143)
      $resp  = $cl.SendAsync($req).GetAwaiter().GetResult()
      $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      $text  = [Text.Encoding]::ASCII.GetString($bytes)
      $m = [regex]::Match($text, '(?im)^Message-ID\s*:\s*<([^>]+)>')
      [void]$dict.TryAdd($name, $(if ($m.Success) { $m.Groups[1].Value } else { '' }))
      $resp.Dispose(); $req.Dispose()
    } catch {
      [void]$dict.TryAdd($name, '')
    }
  }
  $sw.Stop()
  Write-Host ("  chunk {0}/{1}: {2} read in {3}s" -f ($i+1), $chunks, $slice.Count, [math]::Round($sw.Elapsed.TotalSeconds))
}

$proven = @(); $unproven = @(); $unreadable = @()
foreach ($p in $pairs) {
  $oid = $ids[$p.Old]
  if ([string]::IsNullOrEmpty($oid)) { $unreadable += $p.Old; continue }
  $hit = $false
  foreach ($n in $p.New) { if ($ids[$n] -eq $oid) { $hit = $true; break } }
  if ($hit) { $proven += $p.Old } else { $unproven += $p.Old }
}
$proven   | Set-Content (Join-Path $sp 'proven-redundant.txt')
$unproven | Set-Content (Join-Path $sp 'unproven-keep.txt')
$unreadable | Set-Content (Join-Path $sp 'unreadable-keep.txt')

Write-Host ""
Write-Host "PROVEN redundant (safe to delete) : $($proven.Count)"
Write-Host "unproven - different message, KEEP: $($unproven.Count)"
Write-Host "Message-ID unreadable, KEEP       : $($unreadable.Count)"
Write-Host ""
Write-Host ("would have deleted {0} messages that are NOT redundant" -f ($unproven.Count + $unreadable.Count))

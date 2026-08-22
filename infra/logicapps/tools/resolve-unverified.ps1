#requires -Version 7
<#
Resolve every Teams email to a definite state, and persist the per-file result.

The previous pass left 153 files unresolved - 113 with no Message-ID readable from the first
256 KB, and 40 whose reads failed under throttling - but it only saved the gap list, so those
153 could not be identified afterwards. This saves a result for every file so that never
happens again.

Two improvements over the ranged-regex approach:

  - anything the ranged read cannot resolve is downloaded IN FULL and parsed with MimeKit,
    which handles folded headers, unusual encodings and a Message-ID sitting beyond 256 KB.
    A regex over a fixed prefix cannot.
  - if MimeKit also finds no Message-ID, the file is hashed (SHA-256). A message with no
    Message-ID at all is not a failure to read - it is a message that cannot be matched by
    identity, and it needs a different disposition, not a silent "unknown".

Read-only. Writes teams-resolution.json.
#>
param([int]$GraphParallel = 6, [int]$ChunkSize = 3000)
$ErrorActionPreference = 'Stop'
$sp      = $PSScriptRoot
$az      = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$mimeDir = 'C:\Development\REPO\RSE-Law\RegExAzFunc\bin\Debug\net10.0'

$archiveSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($l in (Get-Content (Join-Path $sp 'archive-msgids.txt'))) { if ("$l".Trim()) { [void]$archiveSet.Add("$l".Trim()) } }
Write-Host "cached archive Message-IDs: $($archiveSet.Count)"

$inv = Get-Content (Join-Path $sp 'teams-inventory.json') -Raw | ConvertFrom-Json
Write-Host "Teams files: $($inv.Count)"

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(300)
$res = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

$chunks = [math]::Ceiling($inv.Count / $ChunkSize)
for ($i = 0; $i -lt $chunks; $i++) {
  $slice = $inv[($i*$ChunkSize)..([math]::Min(($i+1)*$ChunkSize-1, $inv.Count-1))]
  $tok = (& $az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $slice | ForEach-Object -ThrottleLimit $GraphParallel -Parallel {
    # bind $using: values to locals first - a method call directly on a $using variable is a
    # parse error ("Expression is not allowed in a Using expression")
    $f = $_; $cl = $using:client; $tk = $using:tok; $bag = $using:res; $md = $using:mimeDir
    $aset = $using:archiveSet
    $url = "https://graph.microsoft.com/v1.0/groups/$($f.GroupId)/drive/items/$($f.ItemId)/content"

    function Fetch($ranged) {
      $a = 0
      while ($true) {
        $a++
        try {
          $r = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
          $r.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $tk)
          if ($ranged) { $r.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 262143) }
          $resp = $cl.SendAsync($r).GetAwaiter().GetResult()
          $code = [int]$resp.StatusCode
          if ($code -in @(429,503,504,500) -and $a -lt 6) {
            $w = 2*$a
            if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $w = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds }
            $resp.Dispose(); $r.Dispose(); Start-Sleep -Seconds ([math]::Min($w,30)); continue
          }
          if (-not $resp.IsSuccessStatusCode) { $resp.Dispose(); $r.Dispose(); return @{ Err = "HTTP $code" } }
          $b = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
          $resp.Dispose(); $r.Dispose()
          return @{ Bytes = $b }
        } catch {
          if ($a -ge 6) { return @{ Err = 'EX' } }
          Start-Sleep -Seconds (2*$a)
        }
      }
    }

    $out = [ordered]@{ Matter=$f.Matter; Name=$f.Name; GroupId=$f.GroupId; ItemId=$f.ItemId; Size=$f.Size
                       MessageId=''; State=''; Hash='' }
    $g = Fetch $true
    if ($g.Err) { $out.State = "readfail:$($g.Err)"; $bag.Add([pscustomobject]$out); return }
    $m = [regex]::Match([Text.Encoding]::ASCII.GetString($g.Bytes), '(?im)^Message-ID\s*:\s*<([^>]+)>')
    if ($m.Success) { $out.MessageId = $m.Groups[1].Value }
    else {
      # ranged regex failed - download whole file and let MimeKit decide
      $full = Fetch $false
      if ($full.Err) { $out.State = "readfail:$($full.Err)"; $bag.Add([pscustomobject]$out); return }
      try {
        Add-Type -Path (Join-Path $md 'BouncyCastle.Cryptography.dll') -ErrorAction SilentlyContinue
        Add-Type -Path (Join-Path $md 'MimeKit.dll') -ErrorAction SilentlyContinue
        $ms = [IO.MemoryStream]::new($full.Bytes)
        $msg = [MimeKit.MimeMessage]::Load($ms)
        if ($msg.MessageId) { $out.MessageId = "$($msg.MessageId)".Trim('<','>') }
        $ms.Dispose()
      } catch { }
      if (-not $out.MessageId) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $out.Hash = [BitConverter]::ToString($sha.ComputeHash($full.Bytes)).Replace('-','')
        $sha.Dispose()
      }
    }
    if     (-not $out.MessageId)                  { $out.State = 'no-message-id' }
    elseif ($aset.Contains($out.MessageId)) { $out.State = 'matched' }
    else                                          { $out.State = 'teams-only' }
    $bag.Add([pscustomobject]$out)
  }
  $sw.Stop()
  Write-Host ("  chunk {0}/{1}: {2} in {3}s" -f ($i+1), $chunks, $slice.Count, [math]::Round($sw.Elapsed.TotalSeconds))
}
$client.Dispose()

$all = @($res)
$all | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $sp 'teams-resolution.json') -Encoding utf8
Write-Host ""
$all | Group-Object State | Sort-Object Count -Descending | ForEach-Object { "  {0,6}  {1}" -f $_.Count, $_.Name }
Write-Host ""
Write-Host "total resolved: $($all.Count) of $($inv.Count)"
$noid = @($all | Where-Object State -eq 'no-message-id')
if ($noid.Count) {
  Write-Host ""
  Write-Host "files with no Message-ID at all (cannot be matched by identity):"
  $noid | Select-Object -First 10 | ForEach-Object { "  {0,-10} {1,8} B  {2}" -f $_.Matter, $_.Size, $_.Name.Substring(0,[math]::Min(60,$_.Name.Length)) }
}


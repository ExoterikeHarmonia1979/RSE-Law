#requires -Version 7
<#
Make the search indexer revisit blobs it has already skipped.

A blob indexer tracks progress with a high-water mark on LastModified. If a document fails
- because the service was out of storage, or a skill timed out - the indexer records the
failure and moves on, and it will never look at that blob again. Re-running the indexer
does not help.

Setting a blob's metadata updates its LastModified without touching its content, which
puts it back ahead of the high-water mark. The next indexer run then treats it as new.

This is the surgical alternative to `POST /indexers/{name}/reset`, which reprocesses the
entire corpus - every document through the custom skill and the embedding model again.
That is the right tool for a small, known set of blobs; a full reset is the right tool
when the affected set is not known.

  ./reindex-touch.ps1 -Prefix "06.222/"                       # dry run
  ./reindex-touch.ps1 -Prefix "06.222/" -Execute
  ./reindex-touch.ps1 -Prefix "" -Since 2026-09-03T08:00 -Until 2026-09-03T21:00 -Execute
#>
param(
  [string]$Prefix = '',
  [datetime]$Since = [datetime]::MinValue,
  [datetime]$Until = [datetime]::MaxValue,
  [string]$Account = 'samatters',
  [string]$Container = 'matters',
  [int]$Parallel = 12,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"

# Refresh on the token's real expiry, not on elapsed time. `az account get-access-token`
# hands back a CACHED token, so one fetched at the start of a long run can already be most
# of the way through its life. A first version of this took the token once and touched
# 87,900 blobs with it: 68,476 succeeded and the remaining 19,424 all failed 401 when it
# expired mid-run. Same mistake ingest-run.ps1 made, same fix.
$script:token = ''
$script:tokenExp = [datetime]::MinValue
function Get-StorageToken {
  $j = (& $az account get-access-token --resource https://storage.azure.com/ -o json) | ConvertFrom-Json
  if (-not $j.accessToken) { throw "no storage token - run 'az login'" }
  $script:token = $j.accessToken
  $script:tokenExp = if ($j.expiresOn) { [datetime]::Parse($j.expiresOn) } else { (Get-Date).AddMinutes(50) }
}
Get-StorageToken
Write-Host ("storage token valid until {0:HH:mm}" -f $script:tokenExp)

# --query with a bracket in it breaks az.cmd's argument parsing, so ask for the raw two
# columns and filter here instead.
Write-Host ("listing {0}/{1} ..." -f $Container, $(if ($Prefix) { $Prefix } else { '(whole container)' }))
# --prefix "" is not the same as omitting it: az rejects an empty value with
# "argument --prefix: expected one argument" and exits 2, which reads as an empty
# container rather than a failed call. Build the arguments conditionally.
#
# --num-results "*" is not optional. Without it az stops at 5,000 blobs and reports
# success, so a container-wide run silently considers a fraction of a percent of the
# container and reports a confident, tiny number. sweep-older-mail.ps1 has used this
# since it was written; this script did not, and the first full run "found" 66 blobs.
$argv = @('storage','blob','list','--account-name',$Account,'--container-name',$Container,
          '--num-results','*','--auth-mode','login',
          '--query','[].[name,properties.lastModified]','-o','tsv')
if ($Prefix) { $argv += @('--prefix', $Prefix) }
$raw = & $az @argv 2>$null
if ($LASTEXITCODE -ne 0) { throw "blob list failed (az exit $LASTEXITCODE)" }

$all = @($raw) | ForEach-Object {
  $p = $_ -split "`t"
  # az emits pagination notices on a long listing; anything without a parseable date is
  # not a blob row.
  if ($p.Count -ge 2) {
    # try/catch, not [datetime]::TryParse - PowerShell cannot bind the two-argument
    # overload ("Cannot find an overload for TryParse and the argument count 2").
    try { [pscustomobject]@{ Name = $p[0]; Mod = [datetime]$p[1] } } catch { }
  }
}

# Same guard as sweep-older-mail.ps1: a short listing means the call was truncated or
# failed, not that the container is small. Deciding what to reindex from a partial
# listing is worse than not running at all, because the result looks like an answer.
if (-not $Prefix -and $all.Count -lt 100000) {
  throw "container listing returned only $($all.Count) blobs - refusing to decide from that"
}
Write-Host ("{0:N0} blob(s) listed" -f $all.Count)

$blobs = @($all | Where-Object { $_.Mod -ge $Since -and $_.Mod -le $Until })
Write-Host ("{0:N0} blob(s) in range" -f $blobs.Count)
if (-not $blobs) { return }
if (-not $Execute) {
  $blobs | Select-Object -First 10 | ForEach-Object { "  would touch  {0:yyyy-MM-dd HH:mm}  {1}" -f $_.Mod, $_.Name }
  Write-Host "`nre-run with -Execute to touch them."
  return
}

$done = 0; $failed = 0
$chunks = [Math]::Ceiling($blobs.Count / 500)
for ($i = 0; $i -lt $blobs.Count; $i += 500) {
  # five minutes of headroom so a chunk cannot straddle the expiry
  if ((Get-Date) -gt $script:tokenExp.AddMinutes(-5)) { Get-StorageToken }
  $tok = $script:token
  $chunk = $blobs[$i..([Math]::Min($i + 499, $blobs.Count - 1))]
  $res = $chunk | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    $enc = ($_.Name -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $uri = "https://$($using:Account).blob.core.windows.net/$($using:Container)/$enc`?comp=metadata"
    try {
      # Metadata only - the blob's content is not read or rewritten. The point is purely
      # the LastModified bump this causes.
      $r = Invoke-WebRequest -Method Put -Uri $uri -Headers @{
        Authorization    = "Bearer $($using:tok)"
        'x-ms-version'   = '2021-12-02'
        'x-ms-meta-reindex' = [string](Get-Date -Format 'yyyyMMddHHmm')
      } -SkipHttpErrorCheck
      [pscustomobject]@{ ok = ($r.StatusCode -eq 200); code = [int]$r.StatusCode; name = $_.Name }
    } catch {
      [pscustomobject]@{ ok = $false; code = -1; name = $_.Name; err = $_.Exception.Message }
    }
  }
  foreach ($r in $res) {
    if ($r.ok) { $done++ } else { $failed++; Write-Warning "touch failed ($($r.code)) $($r.name)" }
  }
  Write-Host ("  {0:N0}/{1:N0}" -f $done, $blobs.Count)
}

Write-Host ""
Write-Host ("touched {0:N0}, failed {1:N0}" -f $done, $failed)
Write-Host "The next indexer run will pick these up. To start one now:"
Write-Host "  POST https://<service>.search.windows.net/indexers/matters-eml-indexer/run?api-version=2024-07-01"

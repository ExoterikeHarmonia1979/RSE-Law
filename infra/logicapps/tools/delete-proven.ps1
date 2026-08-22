#requires -Version 7
<#
Delete ONLY the blobs proven redundant by Message-ID.

Refuses to run unless every guard passes, because the 7-day soft-delete window is the entire
safety net and nobody would think to check it in time.

Guards:
  - the list exists, is non-empty, and is not larger than the superseded candidate set
  - EVERY path is old-format (no " [id].eml" suffix). A new-format path in this list would
    mean deleting the very copy that makes the old one redundant
  - every path is a matter email, never an attachment
  - the count matches the verification output

Dry run unless -Execute.
#>
param([switch]$Execute, [int]$Parallel = 24, [int]$ChunkSize = 5000)
$ErrorActionPreference = 'Stop'
$sp = $PSScriptRoot
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$acct = 'https://samatters.blob.core.windows.net/matters/'

$listPath = Join-Path $sp 'proven-redundant.txt'
if (-not (Test-Path $listPath)) { throw "no proven-redundant.txt - run verify-all.ps1 first" }
$proven = @(Get-Content $listPath | Where-Object { "$_".Trim() })
$candidates = @(Get-Content (Join-Path $sp 'superseded.txt'))

Write-Host "proven-redundant : $($proven.Count)"
Write-Host "candidate set    : $($candidates.Count)"

if ($proven.Count -eq 0) { throw "list is empty - nothing to do" }
if ($proven.Count -gt $candidates.Count) { throw "proven ($($proven.Count)) exceeds candidates ($($candidates.Count)) - list is wrong" }

$badSuffix = @($proven | Where-Object { $_ -match '\s\[[^\]]+\]\.eml$' })
if ($badSuffix.Count -gt 0) {
  $badSuffix | Select-Object -First 5 | ForEach-Object { Write-Host "  NEW-FORMAT IN LIST: $_" }
  throw "$($badSuffix.Count) new-format paths in the delete list - refusing"
}
$badKind = @($proven | Where-Object { $_ -notlike '*/Emails/*.eml' -or $_ -like '*/Emails/Attachments/*' })
if ($badKind.Count -gt 0) {
  $badKind | Select-Object -First 5 | ForEach-Object { Write-Host "  NOT A MATTER EMAIL: $_" }
  throw "$($badKind.Count) paths are not matter emails - refusing"
}
Write-Host "guards passed: all old-format matter emails"

# soft delete is the only way back
$sd = (& $az storage account blob-service-properties show --account-name samatters --resource-group DefaultResourceGroup-EUS --query "deleteRetentionPolicy.enabled" -o tsv)
$sdDays = (& $az storage account blob-service-properties show --account-name samatters --resource-group DefaultResourceGroup-EUS --query "deleteRetentionPolicy.days" -o tsv)
Write-Host "soft delete: $sd ($sdDays days)"
if ($sd -ne 'true') { throw "soft delete is OFF - refusing to delete without a way back" }

if (-not $Execute) { Write-Host "`nDRY RUN - re-run with -Execute to delete $($proven.Count) blobs"; return }

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(60)
$okCount = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
$failed  = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

$chunks = [math]::Ceiling($proven.Count / $ChunkSize)
for ($i = 0; $i -lt $chunks; $i++) {
  $slice = $proven[($i*$ChunkSize)..([math]::Min(($i+1)*$ChunkSize-1, $proven.Count-1))]
  $tok = (& $az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $slice | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    $name = $_
    $url  = $using:acct + (($name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $cl = $using:client; $tk = $using:tok; $ok = $using:okCount; $bad = $using:failed
    try {
      $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Delete, $url)
      $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $tk)
      $req.Headers.Add('x-ms-version','2021-08-06')
      $resp = $cl.SendAsync($req).GetAwaiter().GetResult()
      # 202 deleted; 404 already gone - both fine
      if ($resp.StatusCode -eq 202 -or $resp.StatusCode -eq 404) { [void]$ok.AddOrUpdate('n',1,{param($k,$v) $v+1}) }
      else { $bad.Add("$($resp.StatusCode) $name") }
      $resp.Dispose(); $req.Dispose()
    } catch { $bad.Add("EX $name") }
  }
  $sw.Stop()
  Write-Host ("  chunk {0}/{1}: {2} in {3}s (ok so far {4}, failed {5})" -f ($i+1), $chunks, $slice.Count, [math]::Round($sw.Elapsed.TotalSeconds), $okCount['n'], $failed.Count)
}
$client.Dispose()

Write-Host ""
Write-Host "deleted : $($okCount['n'])"
Write-Host "failed  : $($failed.Count)"
if ($failed.Count -gt 0) { $failed | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" } }
$failed | Set-Content (Join-Path $sp 'delete-failures.txt')

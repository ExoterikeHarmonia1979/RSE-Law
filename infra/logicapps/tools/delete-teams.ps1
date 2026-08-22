#requires -Version 7
<#
Delete the 676 matter Teams, after their content was proven redundant.

Evidence this rests on (all measured, not assumed):
  - 12,206 files inventoried across all 676 Teams; 100% .eml, no working documents
  - 11,421 matched into the blob archive by RFC 5322 Message-ID
  -    672 existed only in Teams and have been uploaded and verified
  -    113 are not email at all - they are Graph "ErrorItemNotFound" payloads the old flow
         wrote into .eml files; two distinct hashes across all 113
  -      0 left in an unknown state

Known and accepted limits, recorded here because they are irreversible after 30 days:
  - 161 attachments exist only INSIDE their .eml rather than as separate blobs. Their text
    is indexed and searchable; they are not standalone files.
  - SharePoint version history and recycle-bin contents are NOT in the archive. That is the
    bulk of the 519.7 GB the Teams reported; live content was 8.11 GB.

Deleting an M365 group removes its mailbox, SharePoint site, Teams channels and files.
Microsoft retains deleted groups for 30 days, restorable from directory deletedItems - that
window is the only way back, so a manifest is written BEFORE anything is deleted.

Guards - it throws rather than proceeds if any fail:
  - every target's displayName must be EXACTLY a matter number
  - the target count must be within 10% of the 676 that were inventoried and proven
  - a manifest must have been written successfully first

Dry run unless -Execute.
#>
param([switch]$Execute, [int]$Parallel = 4)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tok = (& $az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
$H   = @{ Authorization = "Bearer $tok" }

$groups = @(); $u = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName,mail,createdDateTime,visibility,resourceProvisioningOptions&`$top=999"
while ($u) { $p = Invoke-RestMethod -Headers $H -Uri $u; $groups += $p.value; $u = $p.'@odata.nextLink' }
$targets = @($groups | Where-Object { "$($_.displayName)" -match '^\s*\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?\s*$' })
Write-Host "tenant groups: $($groups.Count)   matter Teams targeted: $($targets.Count)"

# --- guards
$bad = @($targets | Where-Object { "$($_.displayName)".Trim() -notmatch '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$' })
if ($bad.Count) { $bad | Select-Object -First 5 | ForEach-Object { Write-Host "  NOT A MATTER NAME: $($_.displayName)" }; throw "refusing - $($bad.Count) targets are not matter-named" }
if ($targets.Count -lt 608 -or $targets.Count -gt 744) { throw "expected ~676 targets, found $($targets.Count) - refusing" }

$inv = Get-Content (Join-Path $sp 'teams-inventory.json') -Raw | ConvertFrom-Json
$invMatters = @{}; foreach ($f in $inv) { $invMatters["$($f.Matter)"] = $true }
$unknown = @($targets | Where-Object { -not $invMatters.ContainsKey("$($_.displayName)".Trim()) })
if ($unknown.Count) {
  $unknown | Select-Object -First 10 | ForEach-Object { Write-Host "  NEVER INVENTORIED: $($_.displayName)" }
  throw "refusing - $($unknown.Count) targets were never inventoried, so their content was never proven redundant"
}
Write-Host "guards passed: all targets matter-named and previously inventoried"

# --- manifest BEFORE deleting: ids, names, members, site URLs
$manifest = @()
foreach ($g in $targets) {
  $members = @(); $site = ''
  try { $members = @((Invoke-RestMethod -Headers $H -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members?`$select=displayName,userPrincipalName").value | ForEach-Object { $_.userPrincipalName }) } catch { }
  try { $site = (Invoke-RestMethod -Headers $H -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/sites/root?`$select=webUrl").webUrl } catch { }
  $manifest += [pscustomobject]@{
    Id = $g.id; DisplayName = "$($g.displayName)".Trim(); Mail = $g.mail
    Created = $g.createdDateTime; SiteUrl = $site; Members = ($members -join '; ')
    Files = @($inv | Where-Object { "$_.Matter" }).Count
  }
}
$manifestPath = Join-Path $sp 'deleted-teams-manifest.csv'
$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding utf8
if (-not (Test-Path $manifestPath)) { throw "manifest was not written - refusing to delete without a record" }
Write-Host "manifest written: $manifestPath ($($manifest.Count) rows)"

if (-not $Execute) {
  Write-Host ""
  Write-Host "DRY RUN - would delete $($targets.Count) groups. Sample:"
  $targets | Select-Object -First 8 | ForEach-Object { "  $($_.displayName.Trim())   $($_.mail)" }
  Write-Host ""
  Write-Host "re-run with -Execute to delete. Recoverable for 30 days via directory deletedItems."
  return
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(120)
$ok = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
$errs = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

$targets | ForEach-Object -ThrottleLimit $Parallel -Parallel {
  $g = $_; $cl = $using:client; $tk = $using:tok; $okc = $using:ok; $bad = $using:errs
  $attempt = 0
  while ($true) {
    $attempt++
    try {
      $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Delete, "https://graph.microsoft.com/v1.0/groups/$($g.id)")
      $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $tk)
      $resp = $cl.SendAsync($req).GetAwaiter().GetResult()
      $code = [int]$resp.StatusCode
      if ($code -in @(429,503,504) -and $attempt -lt 6) {
        $w = 3 * $attempt
        if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $w = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds }
        $resp.Dispose(); $req.Dispose(); Start-Sleep -Seconds ([math]::Min($w,30)); continue
      }
      if ($code -eq 204 -or $code -eq 404) { [void]$okc.AddOrUpdate('n',1,{param($k,$v) $v+1}) }
      else { $bad.Add("$code $($g.displayName)") }
      $resp.Dispose(); $req.Dispose(); break
    } catch {
      if ($attempt -ge 6) { $bad.Add("EX $($g.displayName)"); break }
      Start-Sleep -Seconds (3 * $attempt)
    }
  }
}
$client.Dispose()

Write-Host ""
Write-Host "deleted : $($ok['n'])"
Write-Host "failed  : $($errs.Count)"
$errs | Set-Content (Join-Path $sp 'delete-teams-failures.txt')
if ($errs.Count) { $errs | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" } }

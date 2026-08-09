#requires -Version 7
<#
Deploy HTTP-Matter-On-Email-Receipt, refusing to clobber changes made outside this repo.

The problem this exists to stop: transform.ps1 rebuilds the definition from before.json,
a snapshot taken once. Anything changed directly on the live workflow and not mirrored
back into the repo is silently reverted by the next PUT. That is not hypothetical - the
trigger concurrency sat at 100 live and 40 in the repo, and a redeploy would have quietly
halved throughput with nothing in the output to say so.

Comparing live against the *new* definition cannot detect this, because every intentional
change is also a difference. So this keeps a baseline - deployed.json, the definition as
this tooling last PUT it - and compares live against that:

    live == baseline   -> nobody edited live behind our back, safe to deploy
    live != baseline   -> out-of-band drift, stop and show it

After a successful PUT the baseline is rewritten, so the next run compares against what
was actually deployed.

  ./deploy.ps1                 # dry run: report drift and what would change
  ./deploy.ps1 -Execute        # deploy, refusing if live has drifted
  ./deploy.ps1 -Execute -AcceptDrift   # deploy anyway, discarding the live-only changes
#>
param(
  [switch]$Execute,
  [switch]$AcceptDrift,
  [string]$DefPath      = "$PSScriptRoot\HTTP-Matter-On-Email-Receipt.after.json",
  [string]$BaselinePath = "$PSScriptRoot\deployed.json",
  [string]$ResourceGroup = 'Sharepoint1',
  [string]$Workflow      = 'HTTP-Matter-On-Email-Receipt'
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"

# Returned by ARM but never authored by us - comparing it reports drift on every run.
$computed = @('evaluatedRecurrence')

function Canon($o) {
  if ($o -is [pscustomobject]) {
    $out = [ordered]@{}
    foreach ($k in ($o.PSObject.Properties.Name | Sort-Object)) {
      if ($computed -contains $k) { continue }
      $out[$k] = Canon $o.$k
    }
    return $out
  }
  if ($o -is [object[]]) { return @($o | ForEach-Object { Canon $_ }) }
  return $o
}
function Json($o) { Canon $o | ConvertTo-Json -Depth 100 -Compress }

# Walk two trees and report differing paths, so the message names the setting that moved
# rather than dumping 60KB of JSON at whoever is deploying.
function DiffPaths($a, $b, $path = '', [ref]$acc) {
  if ($acc.Value.Count -ge 40) { return }
  $aObj = $a -is [pscustomobject]; $bObj = $b -is [pscustomobject]
  if ($aObj -and $bObj) {
    $keys = @($a.PSObject.Properties.Name) + @($b.PSObject.Properties.Name) | Sort-Object -Unique
    foreach ($k in $keys) {
      if ($computed -contains $k) { continue }
      $hasA = $a.PSObject.Properties.Name -contains $k
      $hasB = $b.PSObject.Properties.Name -contains $k
      # $a is live, $b is baseline - keep these the right way round, a swapped label
      # sends whoever is deploying looking for the change in the wrong place
      if (-not $hasA) { $acc.Value.Add("$path.$k : missing from live, present in baseline"); continue }
      if (-not $hasB) { $acc.Value.Add("$path.$k : present on live only, not in baseline"); continue }
      DiffPaths $a.$k $b.$k "$path.$k" $acc
    }
    return
  }
  if ($a -is [object[]] -and $b -is [object[]]) {
    if ($a.Count -ne $b.Count) { $acc.Value.Add("$path : array length $($a.Count) vs $($b.Count)"); return }
    for ($i = 0; $i -lt $a.Count; $i++) { DiffPaths $a[$i] $b[$i] "$path[$i]" $acc }
    return
  }
  if ((Json $a) -ne (Json $b)) {
    $av = "$a"; $bv = "$b"
    if ($av.Length -gt 60) { $av = $av.Substring(0,60) + '...' }
    if ($bv.Length -gt 60) { $bv = $bv.Substring(0,60) + '...' }
    $acc.Value.Add("$path : live='$av' baseline='$bv'")
  }
}

# ---------------------------------------------------------------- fetch live
$token = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$sub   = (& $az account show --query id -o tsv)
$uri   = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$Workflow`?api-version=2019-05-01"
$h     = @{ Authorization = "Bearer $token" }
$live  = Invoke-RestMethod -Uri $uri -Headers $h
Write-Host "live: state=$($live.properties.state) provisioning=$($live.properties.provisioningState)"

$new = Get-Content $DefPath -Raw | ConvertFrom-Json

# ------------------------------------------------------- drift: live vs baseline
$drift = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path $BaselinePath)) {
  Write-Host "no baseline at $BaselinePath - cannot tell intentional live changes from drift."
  Write-Host "Treating this run as the one that establishes it; review the dry-run diff below carefully."
} else {
  $baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json
  DiffPaths $live.properties.definition $baseline.definition 'definition' ([ref]$drift)
  DiffPaths $live.properties.parameters $baseline.parameters 'parameters' ([ref]$drift)
  if ($drift.Count -eq 0) {
    Write-Host "no drift: live matches the last deployed baseline"
  } else {
    Write-Host ""
    Write-Host "DRIFT - live differs from the last deployed baseline in $($drift.Count) place(s):" -ForegroundColor Yellow
    $drift | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Someone changed the live workflow outside this repo. Deploying now discards"
    Write-Host "those changes. Mirror them into transform.ps1 first, or re-run with -AcceptDrift."
  }
}

# --------------------------------------------- what this deploy would change
$pending = New-Object System.Collections.Generic.List[string]
DiffPaths $live.properties.definition $new.properties.definition 'definition' ([ref]$pending)
if ($pending.Count -eq 0) {
  Write-Host "`nlive already matches $([IO.Path]::GetFileName($DefPath)) - nothing to deploy"
} else {
  Write-Host "`nthis deploy would change $($pending.Count) place(s) (live -> repo):"
  $pending | ForEach-Object { Write-Host "  $_" }
}

if (-not $Execute) { Write-Host "`nDRY RUN - re-run with -Execute to deploy"; return }
if ($drift.Count -gt 0 -and -not $AcceptDrift) { throw "refusing to deploy over live drift; use -AcceptDrift to override" }

# ------------------------------------------------------------------- deploy
# Only the writable properties, and identity must be included or the PUT strips the
# managed identity that every Graph call authenticates with.
$payload = @{
  location   = $new.location
  identity   = @{ type = $new.identity.type }
  tags       = $new.tags
  properties = @{
    definition = $new.properties.definition
    parameters = $new.properties.parameters
    state      = $new.properties.state
  }
} | ConvertTo-Json -Depth 100

$r = Invoke-RestMethod -Method Put -Uri $uri -Headers $h -ContentType 'application/json' `
       -Body ([Text.Encoding]::UTF8.GetBytes($payload))
Write-Host "deployed: provisioning=$($r.properties.provisioningState) state=$($r.properties.state) identity=$($r.identity.principalId)"
if ($r.properties.state -ne 'Enabled') { Write-Warning "workflow is $($r.properties.state), not Enabled" }

# new baseline = what we just deployed, read back from ARM so it reflects what ARM stored
[pscustomobject]@{
  capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
  workflow    = $Workflow
  definition  = $r.properties.definition
  parameters  = $r.properties.parameters
} | ConvertTo-Json -Depth 100 | Set-Content $BaselinePath -Encoding utf8
Write-Host "baseline updated: $BaselinePath"

#requires -Version 7
<#
Deploy HTTP-Matter-On-Email-Receipt, refusing to clobber changes made outside this repo.

The problem this exists to stop: transform.ps1 rebuilds the definition from before.json,
a frozen snapshot of the original. Anything changed directly on the live workflow and not
mirrored back into transform.ps1 is silently reverted by the next PUT. That is not
hypothetical - the trigger concurrency sat at 100 live and 40 in the repo, and a redeploy
would have quietly halved throughput with nothing in the output to say so.

Drift detection lives in drift.ps1, shared with transform.ps1 so both agree on what
counts as an out-of-band edit. See that file for why live is compared against a
baseline rather than against the new definition.

  ./deploy.ps1                         # dry run: report drift and what would change
  ./deploy.ps1 -Execute                # deploy, refusing if live has drifted
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
. "$PSScriptRoot\drift.ps1"

$check = Test-WorkflowDrift -BaselinePath $BaselinePath -ResourceGroup $ResourceGroup -Workflow $Workflow

# Deploying needs Azure regardless, so fetch live even when the drift check could not run.
$live = if ($check.Live) { $check.Live } else { Get-LiveWorkflow -ResourceGroup $ResourceGroup -Workflow $Workflow }
Write-Host "live: state=$($live.workflow.properties.state) provisioning=$($live.workflow.properties.provisioningState)"

if (-not $check.Checked) {
  Write-Host "drift NOT checked - $($check.Reason)"
  Write-Host "Cannot tell intentional live changes from an out-of-band edit; review the diff below."
} elseif ($check.Drift.Count -eq 0) {
  Write-Host "no drift: live matches the last deployed baseline"
} else {
  Write-Host ""
  Write-Host "DRIFT - live differs from the last deployed baseline in $($check.Drift.Count) place(s):" -ForegroundColor Yellow
  $check.Drift | ForEach-Object { Write-Host "  $_" }
  Write-Host ""
  Write-Host "Someone changed the live workflow outside this repo. Deploying now discards"
  Write-Host "those changes. Mirror them into transform.ps1 first, or re-run with -AcceptDrift."
}

$new = Get-Content $DefPath -Raw | ConvertFrom-Json

# --------------------------------------------- what this deploy would change
$pending = New-Object System.Collections.Generic.List[string]
Add-DriftPaths $live.workflow.properties.definition $new.properties.definition 'definition' ([ref]$pending)
if ($pending.Count -eq 0) {
  Write-Host "`nlive already matches $([IO.Path]::GetFileName($DefPath)) - nothing to deploy"
} else {
  Write-Host "`nthis deploy would change $($pending.Count) place(s) (live -> repo):"
  $pending | ForEach-Object { Write-Host "  $_" }
}

if (-not $Execute) { Write-Host "`nDRY RUN - re-run with -Execute to deploy"; return }
if ($check.Drift.Count -gt 0 -and -not $AcceptDrift) { throw "refusing to deploy over live drift; use -AcceptDrift to override" }

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

$r = Invoke-RestMethod -Method Put -Uri $live.uri -Headers $live.headers -ContentType 'application/json' `
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

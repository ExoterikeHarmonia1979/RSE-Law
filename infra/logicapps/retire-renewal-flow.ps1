#requires -Version 7
<#
Retire the Renew-GraphAPI-Subscriptions Logic App.

WHY
---
This workflow is the OLD subscription-renewal flow. It was superseded by the GraphSub*
functions in RegExAzFunc - GraphSubNightly runs at 22:00 local and has succeeded every night
for at least twelve consecutive runs. The Logic App itself no longer renews anything: its
definition contains exactly two actions, get a token and list users.

RegExAzFunc/docs/GraphSubscriptions.md sets out the migration, and step 4 is explicit:

    "Turn off the flow's recurrence trigger. Do not run both - two writers PATCHing the
     same subscriptions produce confusing 404s."

That step was never completed, so the retired flow kept firing nightly and failing (its
hardcoded client secret was rotated out on 2026-08-09). Those failures were pure noise, but
noise that reads exactly like an outage - it is what sent this investigation down the wrong
path in the first place.

WHAT THIS DOES
--------------
1. Restores the definition captured before the secret was changed. That deliberately puts the
   STALE secret back: a disabled workflow has no use for a working credential, and a valid
   secret sitting in a definition is readable by anyone with reader access on the resource.
   The stale one is worthless to anybody.
2. Disables the workflow, which completes the documented retirement.

Deleting it outright would also be defensible, but disabling is reversible and keeps the run
history available as evidence of what the old flow did.

Dry run unless -Execute.
#>
param(
  [string]$Backup,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$sp = $PSScriptRoot
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$rg = 'Renew-GraphAPI-Subscriptions_group'
$name = 'Renew-GraphAPI-Subscriptions'

if (-not $Backup) {
  # the earliest backup is the pre-change state; later ones may already contain the new secret
  $Backup = (Get-ChildItem (Join-Path $sp 'renew-subscriptions.backup-*.json') | Sort-Object Name | Select-Object -First 1).FullName
}
if (-not (Test-Path $Backup)) { throw "no backup found to restore from" }
Write-Host "restoring from: $(Split-Path $Backup -Leaf)"

$tok = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$sub = (& $az account show --query id -o tsv)
$H   = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
$wf  = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$name"

$live = Invoke-RestMethod -Uri "$wf`?api-version=2016-06-01" -Headers @{ Authorization = "Bearer $tok" }
Write-Host "current state: $($live.properties.state)"

# Confirm the backup is the pre-change definition rather than a copy of what is live now.
$def = Get-Content $Backup -Raw
$kv = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$hasCurrent = $def -match [regex]::Escape("client_secret=$kv")
Write-Host ("backup holds the CURRENT secret: {0}" -f $(if ($hasCurrent) { 'yes - restoring it would leave a live credential in a disabled workflow' } else { 'no - it holds the stale one, which is what we want' }))

Write-Host ("`n{0}: restore the pre-change definition, then disable the workflow" -f $(if ($Execute) { 'EXECUTING' } else { 'DRY RUN' }))
if (-not $Execute) { Write-Host "re-run with -Execute to apply."; return }

$body = @{
  location   = $live.location
  properties = @{ definition = ($def | ConvertFrom-Json); parameters = $live.properties.parameters }
} | ConvertTo-Json -Depth 60
$r = Invoke-RestMethod -Method Put -Uri "$wf`?api-version=2016-06-01" -Headers $H -Body $body
Write-Host "  definition restored: provisioning=$($r.properties.provisioningState)"

Invoke-RestMethod -Method Post -Uri "$wf/disable?api-version=2016-06-01" -Headers $H | Out-Null
$after = Invoke-RestMethod -Uri "$wf`?api-version=2016-06-01" -Headers @{ Authorization = "Bearer $tok" }
Write-Host "  state now: $($after.properties.state)"
if ($after.properties.state -ne 'Disabled') { throw "expected Disabled, got $($after.properties.state)" }
Write-Host "`nretired. GraphSubNightly remains the single writer, as the migration doc intends."

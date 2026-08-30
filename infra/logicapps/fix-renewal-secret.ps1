#requires -Version 7
<#
Repoint Renew-GraphAPI-Subscriptions at the current client secret.

THE FAILURE
-----------
The workflow renews all 20 Graph change-notification subscriptions daily. It has failed every
run since 2026-08-09 - its first action, HTTP_Get_Access_Token, returns 401 - so nothing has
been renewed for three weeks and the subscriptions expire 2026-09-03 05:00 UTC. When they
lapse, the archive stops receiving notifications for every mailbox.

THE CAUSE
---------
The app secret was rotated on 2026-08-09. Key Vault (kv-rse-graphsubs/GraphSubClientSecret)
was updated and still works; the Logic App was not, because it carries its own copy of the
secret hardcoded in the definition. Last successful run: 2026-08-08, the day before the
rotation. The two facts line up exactly.

WHAT THIS DOES, AND WHAT IT DOES NOT
------------------------------------
It replaces the stale secret with the current one, which restores the renewals now. The new
secret is valid until 2028-08-09.

It does NOT remove the secret from the definition, and that is worth being explicit about:
a hardcoded secret means the next rotation breaks this again, silently, and it took three
weeks to notice this time. It is also visible in plain text in every run's recorded inputs to
anyone with reader access on the workflow. The durable fix is to give the workflow a managed
identity - the archive workflow already has one - and read the secret from Key Vault at run
time, or authenticate to Graph as the identity directly. That is a bigger change than an
expiring-subscription deadline should be spent on, so it is left as a follow-up rather than
attempted here.

Backs the current definition up before changing anything. Dry run unless -Execute.
#>
param([switch]$Execute)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$rg  = 'Renew-GraphAPI-Subscriptions_group'
$name = 'Renew-GraphAPI-Subscriptions'

$tok = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$sub = (& $az account show --query id -o tsv)
$H   = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
$wf  = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$name"

$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
if (-not $secret) { throw "could not read GraphSubClientSecret from Key Vault" }

# Prove the Key Vault secret works BEFORE writing it into the workflow. Deploying a secret
# that is itself invalid would leave the outage in place while looking like a fix.
try {
  $null = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/29b31beb-399c-4432-aa07-9258f6e46620/oauth2/v2.0/token" -Body @{
            client_id='43248a7a-1c76-40fd-91b6-57ec5f08639e'; scope='https://graph.microsoft.com/.default'
            client_secret=$secret; grant_type='client_credentials' }).access_token
  Write-Host "Key Vault secret verified against the token endpoint."
} catch {
  throw "the Key Vault secret does not work either - do not deploy it: $($_.Exception.Message)"
}

$w = Invoke-RestMethod -Uri "$wf`?api-version=2016-06-01" -Headers @{ Authorization = "Bearer $tok" }
$json = $w.properties.definition | ConvertTo-Json -Depth 60

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $sp "renew-subscriptions.backup-$stamp.json"
# The backup contains the old secret, so it stays out of the repo - see .gitignore.
$json | Set-Content $backup -Encoding utf8
Write-Host "backed up the live definition to $(Split-Path $backup -Leaf)"

# Replace whatever client_secret is currently in the body, without needing to know its value.
$pattern = 'client_secret=[^&\\"]+'
$hits = [regex]::Matches($json, $pattern)
Write-Host "client_secret occurrences in the definition: $($hits.Count)"
if ($hits.Count -eq 0) { throw "no client_secret found - the definition is not shaped as expected, stopping" }

$already = $json -match [regex]::Escape("client_secret=$secret")
if ($already) { Write-Host "the definition ALREADY holds the current secret - nothing to change."; return }

$patched = [regex]::Replace($json, $pattern, "client_secret=$secret")
if ($patched -eq $json) { throw "replacement produced no change - stopping rather than deploying a no-op" }

Write-Host ("`n{0}: replace the stale secret in {1} place(s)" -f $(if ($Execute) { 'EXECUTING' } else { 'DRY RUN' }), $hits.Count)
if (-not $Execute) { Write-Host "re-run with -Execute to apply."; return }

$body = @{
  location   = $w.location
  properties = @{ definition = ($patched | ConvertFrom-Json); parameters = $w.properties.parameters }
} | ConvertTo-Json -Depth 60

$r = Invoke-RestMethod -Method Put -Uri "$wf`?api-version=2016-06-01" -Headers $H -Body $body
Write-Host "deployed: provisioning=$($r.properties.provisioningState) state=$($r.properties.state)"

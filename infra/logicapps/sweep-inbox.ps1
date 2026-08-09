#requires -Version 7
<#
Feed an existing mailbox through the archive pipeline.

Replaces the "Unsorted Matters" Power Automate flow, which did the same sweep with its own
copy of the matter-matching logic, its own SharePoint site provisioning, and a client secret
pasted into the flow definition. Rather than repair 126 actions, this enumerates the mailbox
and raises one Service Bus event per message in exactly the shape Graph would send, so the
work is done by HTTP-Matter-On-Email-Receipt - the pipeline that already has managed-identity
auth, peek-lock durability, and a single matter-matching implementation.

Safe to re-run. Blob names are deterministic (matter + sanitised subject), so a message
processed twice overwrites its own blob rather than duplicating it. There is no "processed"
marker on the mailbox, so a repeat sweep genuinely reprocesses everything - that is the
accepted trade-off for not moving or flagging anyone's mail.

Enqueue only. Nothing is read from or written to the mailbox.
#>
param(
  [string]$Mailbox   = 'matters@rse-law.com',
  [string]$Folder    = 'Inbox',
  [int]$Max          = 1000,        # messages to enqueue this run
  [int]$Skip         = 0,           # resume point, in messages
  [int]$BatchSize    = 100,         # Service Bus accepts a batched send
  [switch]$Execute                  # dry run unless set
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

$az     = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tenant = '29b31beb-399c-4432-aa07-9258f6e46620'
$appId  = '43248a7a-1c76-40fd-91b6-57ec5f08639e'

$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$graph  = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
             client_id = $appId; scope = 'https://graph.microsoft.com/.default'
             client_secret = $secret; grant_type = 'client_credentials' }).access_token
$gh = @{ Authorization = "Bearer $graph" }

$uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$Mailbox`?`$select=id" -Headers $gh).id

# --- Service Bus sender (batched)
$ns  = 'sharepointexchangeeventgrid.servicebus.windows.net'
$q   = 'speventgridqueue'
$key = (Get-Content "$env:TEMP\sbkey.txt" -Raw).Trim()
$enc = [System.Web.HttpUtility]::UrlEncode("https://$ns/$q")
$exp = [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s)) + 21600
$hm  = New-Object System.Security.Cryptography.HMACSHA256(, [Text.Encoding]::UTF8.GetBytes($key))
$sig = [Convert]::ToBase64String($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes("$enc`n$exp")))
$sbH = @{ Authorization = "SharedAccessSignature sr=$enc&sig=$([System.Web.HttpUtility]::UrlEncode($sig))&se=$exp&skn=RootManageSharedAccessKey" }

function Send-Batch($items) {
  if (-not $items -or $items.Count -eq 0) { return }
  $payload = @($items | ForEach-Object { @{ Body = $_ } }) | ConvertTo-Json -Depth 5 -AsArray
  Invoke-WebRequest -Method Post -Uri "https://$ns/$q/messages" -Headers $sbH `
    -ContentType 'application/vnd.microsoft.servicebus.json' `
    -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ErrorAction Stop | Out-Null
}

# --- walk the folder, oldest first so the backlog drains in arrival order
$url  = "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$Folder/messages" +
        "?`$select=id&`$top=999&`$orderby=receivedDateTime asc"
$seen = 0; $queued = 0; $batch = @(); $errors = 0

while ($url) {
  $page = Invoke-RestMethod -Uri $url -Headers $gh
  foreach ($m in $page.value) {
    $seen++
    if ($seen -le $Skip) { continue }
    if ($queued -ge $Max) { break }

    $resource = "Users/$uid/Messages/$($m.id)"
    # Shaped to match a real Graph change notification; the workflow reads
    # data.ResourceData['@odata.id'] and data.ResourceData.Id from this.
    $evt = [ordered]@{
      type            = 'Microsoft.Graph.MessageCreated'
      specversion     = '1.0'
      source          = "/tenants/$tenant/applications/$appId"
      subject         = $resource
      id              = [guid]::NewGuid().ToString()
      time            = (Get-Date).ToUniversalTime().ToString('o')
      datacontenttype = 'application/json'
      data            = [ordered]@{
        SubscriptionId                 = 'inbox-sweep'
        SubscriptionExpirationDateTime = (Get-Date).ToUniversalTime().AddDays(1).ToString('o')
        ChangeType                     = 'created'
        Resource                       = $resource
        ResourceData                   = [ordered]@{
          '@odata.type' = '#Microsoft.Graph.Message'
          '@odata.id'   = $resource
          'Id'          = $m.id
        }
      }
    } | ConvertTo-Json -Depth 8 -Compress

    $batch += $evt
    $queued++

    if ($batch.Count -ge $BatchSize) {
      if ($Execute) {
        try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ }
      }
      $batch = @()
      Write-Host "  queued $queued / $Max"
    }
  }
  if ($queued -ge $Max) { break }
  $url = $page.'@odata.nextLink'
}

if ($batch.Count -gt 0 -and $Execute) {
  try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ }
}

Write-Host ("{0}: scanned={1} queued={2} errors={3}  (resume with -Skip {4})" -f `
  $(if ($Execute) { 'EXECUTED' } else { 'DRY RUN' }), $seen, $queued, $errors, ($Skip + $queued))

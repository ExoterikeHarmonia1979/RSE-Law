#requires -Version 7
<#
Archive the older primary-mailbox mail that the sweep never picked up.

Measured 2026-08-29: matters@rse-law.com holds 3,460 messages received before 2026-02-01,
and NOT ONE of them is archived - 0% coverage. They are not in bins or drafts; they sit in
File Cabinet matter folders (06.169 with 979, 100.137 with 696, 98.071 with 544, and more),
which is precisely the mail the archive exists to hold.

This is separate from the In-Place Archive that Jack reported - a second mailbox store
(ArchiveGuid 71f95ab4-4efd-4092-b208-8446b72ba0b0, 425,840 items, 205.8 GB) filled by the
"Matters Archive - 6 Months" retention policy. Everything swept here is in the PRIMARY
mailbox and reachable with the ordinary Graph mail API.

The archive is NOT reachable that way - /users/{id}/mailFolders is the primary store only,
which is why archivemsgfolderroot 404s. It IS reachable through the mailbox import/export
API at /beta/admin/exchange/mailboxes/{inPlaceArchiveMailboxId}, confirmed working against
this tenant, so EWS is not needed and its retirement is not a constraint. That ingest is a
separate job with its own dedup requirement - see build-messageid-index.ps1.

Absence is decided by the message-id tail in the blob name - the same identity the archive
itself uses - so a message already archived is skipped rather than re-sent, and re-running
is safe: blob names are deterministic, so anything re-sent overwrites its own blob.

The folder each message sits in supplies the MatterHint, exactly as sweep-inbox.ps1 does, so
mail whose subject does not name the matter still files under the right one.

Dry run unless -Execute.
#>
param(
  [string]$Mailbox = 'matters@rse-law.com',
  [string]$Before  = '2026-02-01',
  [int]$BatchSize  = 50,
  [int]$Max        = 20000,
  [switch]$RefreshBlobs,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

$sp     = $PSScriptRoot
$az     = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tenant = '29b31beb-399c-4432-aa07-9258f6e46620'
$appId  = '43248a7a-1c76-40fd-91b6-57ec5f08639e'

$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$graph  = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
             client_id = $appId; scope = 'https://graph.microsoft.com/.default'
             client_secret = $secret; grant_type = 'client_credentials' }).access_token
$gh  = @{ Authorization = "Bearer $graph" }
$uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$Mailbox`?`$select=id" -Headers $gh).id

# MUST match transform.ps1 and sweep-inbox.ps1: last 24 chars, '/'->'_', '+'->'-', '=' dropped
function Get-IdTail([string]$id) {
  $t = if ($id.Length -gt 24) { $id.Substring($id.Length - 24, 24) } else { $id }
  $t.Replace('/','_').Replace('+','-').Replace('=','')
}

# Same rule as sweep-inbox.ps1: a folder leaf that is a well-formed RSE file number is a
# classification a person already made. No hint is recoverable; a wrong one misfiles.
function Get-MatterHint([string]$leaf) {
  $t = "$leaf".Trim()
  if ($t -match '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$') { return $t }
  ''
}
$skipFolders = @('Drafts','Deleted Items','Junk Email','Outbox','Conversation History',
                 'Sync Issues','Recoverable Items','RSS Feeds','Clutter','Scheduled')

# --- what is already archived -------------------------------------------------------------
$dump = Join-Path $sp 'archive-blobs.txt'
if ($RefreshBlobs -or -not (Test-Path $dump) -or ((Get-Date) - (Get-Item $dump).LastWriteTime).TotalHours -gt 6) {
  Write-Host "listing the container (a few minutes) ..."
  & $az storage blob list --account-name samatters --container-name matters `
      --num-results "*" --auth-mode login --query "[].name" -o tsv 2>$null | Set-Content $dump
}
$names = @(Get-Content $dump)
if ($names.Count -lt 100000) { throw "container listing returned only $($names.Count) blobs - refusing to decide from that" }
$tails = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($n in $names) { if ($n -match '\[([^\]]+)\]\.eml$') { [void]$tails.Add($Matches[1]) } }
Write-Host "archive holds $($tails.Count) distinct messages"

# --- Service Bus sender (same shape as sweep-inbox.ps1) -----------------------------------
$ns = 'sharepointexchangeeventgrid.servicebus.windows.net'
$q  = 'speventgridqueue'
$key = (& $az servicebus namespace authorization-rule keys list `
          -g Sharepoint1 --namespace-name SharePointExchangeEventGrid `
          -n RootManageSharedAccessKey --query primaryKey -o tsv 2>$null)
if (-not $key -and (Test-Path "$env:TEMP\sbkey.txt")) { $key = (Get-Content "$env:TEMP\sbkey.txt" -Raw) }
$key = "$key".Trim()
if (-not $key) { throw "no Service Bus key available" }

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

# --- walk the old mail --------------------------------------------------------------------
$folderCache = @{}
$seen = 0; $already = 0; $skipped = 0; $queued = 0; $errors = 0
$batch = @(); $report = @(); $byMatter = @{}

$u = "https://graph.microsoft.com/v1.0/users/$uid/messages?`$filter=receivedDateTime lt ${Before}T00:00:00Z" +
     "&`$select=id,subject,receivedDateTime,parentFolderId&`$top=200"
while ($u -and $queued -lt $Max) {
  $page = $null
  for ($try = 1; $try -le 5; $try++) {
    try { $page = Invoke-RestMethod -Uri $u -Headers $gh; break }
    catch {
      $resp = $_.Exception.Response
      if ($resp -and [int]$resp.StatusCode -in 429, 503, 504) {
        $wait = 5 * $try
        try { if ($resp.Headers.RetryAfter.Delta) { $wait = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds } } catch { }
        Start-Sleep -Seconds $wait
      } else { throw }
    }
  }
  if (-not $page) { Write-Warning "giving up on a page after retries"; $errors++; break }

  foreach ($m in $page.value) {
    $seen++
    $tail = Get-IdTail $m.id
    if ($tails.Contains($tail)) { $already++; continue }

    if (-not $folderCache.ContainsKey($m.parentFolderId)) {
      try {
        $f = Invoke-RestMethod -Headers $gh -Uri "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($m.parentFolderId)?`$select=displayName"
        $leaf = "$($f.displayName)".Trim()
        $folderCache[$m.parentFolderId] = [pscustomobject]@{ Leaf = $leaf; Hint = (Get-MatterHint $leaf) }
      } catch { $folderCache[$m.parentFolderId] = [pscustomobject]@{ Leaf = ''; Hint = '' } }
    }
    $leaf = $folderCache[$m.parentFolderId].Leaf
    $hint = $folderCache[$m.parentFolderId].Hint
    if ($leaf -and ($skipFolders -contains $leaf)) { $skipped++; continue }

    $resource = "Users/$uid/Messages/$($m.id)"
    $evt = [ordered]@{
      type            = 'Microsoft.Graph.MessageCreated'
      specversion     = '1.0'
      source          = "/tenants/$tenant/applications/$appId"
      subject         = $resource
      id              = [guid]::NewGuid().ToString()
      time            = (Get-Date).ToUniversalTime().ToString('o')
      datacontenttype = 'application/json'
      data            = [ordered]@{
        SubscriptionId                 = 'older-mail-sweep'
        SubscriptionExpirationDateTime = (Get-Date).ToUniversalTime().AddDays(1).ToString('o')
        ChangeType                     = 'created'
        Resource                       = $resource
        MatterHint                     = $hint
        ResourceData                   = [ordered]@{
          '@odata.type' = '#Microsoft.Graph.Message'
          '@odata.id'   = $resource
          'Id'          = $m.id
        }
      }
    } | ConvertTo-Json -Depth 8 -Compress

    $report += [pscustomobject]@{
      Received = $m.receivedDateTime; Folder = $leaf; Hint = $hint
      Tail = $tail; MessageId = $m.id; Subject = "$($m.subject)"
    }
    $k = if ($leaf) { $leaf } else { '(no folder)' }
    $byMatter[$k] = 1 + ($byMatter[$k] ?? 0)

    if ($Execute) {
      $batch += $evt
      if ($batch.Count -ge $BatchSize) {
        try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ }
        $batch = @()
      }
    }
    $queued++
  }
  $u = $page.'@odata.nextLink'
}
if ($Execute -and $batch.Count) {
  try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ }
}

Write-Host "`n=== mail received before $Before ==="
Write-Host ("  {0,6}  seen in the mailbox" -f $seen)
Write-Host ("  {0,6}  already archived" -f $already)
Write-Host ("  {0,6}  in bins/drafts, skipped by design" -f $skipped)
Write-Host ("  {0,6}  {1}" -f $queued, $(if ($Execute) { 'ENQUEUED' } else { 'would be enqueued' }))
if ($errors) { Write-Host ("  {0,6}  errors" -f $errors) }

Write-Host "`n  by folder (top 12):"
$byMatter.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12 |
  ForEach-Object { "  {0,6}  {1}" -f $_.Value, $_.Key }

$csv = Join-Path $sp ("older-mail-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | Export-Csv $csv -NoTypeInformation -Encoding utf8
Write-Host "`ndetail: $(Split-Path $csv -Leaf)"
if (-not $Execute -and $queued) { Write-Host "re-run with -Execute to enqueue." }

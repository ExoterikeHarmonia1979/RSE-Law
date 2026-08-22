#requires -Version 7
<#
Recover the mail behind Graph "Missed" notifications.

WHAT A MISSED NOTIFICATION IS
-----------------------------
Graph sends {"type":"Missed", "lifecycleEvent":"missed"} to say: messages arrived on this
subscription and we failed to deliver the change notifications for them. It does NOT say
which messages, or how many. The payload carries only a SubscriptionId and a timestamp -
resourceData is null.

The archive workflow finds no OData ID in that payload, skips the message, completes it off
the queue and reports Succeeded. So every Missed event is an unknown quantity of mail that
was never archived, with no record of what it was. Measured over 600 runs spanning 3.7
hours: 21 Missed events across 14 subscriptions, a rate of roughly 137 a day.

WHY THIS RECONCILES BY MAILBOX RATHER THAN BY SUBSCRIPTION
----------------------------------------------------------
The obvious approach - look up the subscription, re-sync just that resource - does not
survive contact with this tenant. Of the 14 subscription ids that appeared in Missed events
over one 3.7-hour window, 13 no longer existed by the time the window closed: the renewal
job replaces subscriptions rather than extending them, so ids churn continuously. A Missed
event is therefore usually unresolvable to a mailbox after the fact.

So the unit of reconciliation is the mailbox, not the subscription. Any Missed event means
"something arrived somewhere in the subscribed set and we did not archive it", and the
answer is to compare the subscribed mailboxes against the archive over the affected window
and enqueue whatever is absent.

That is also strictly more robust: it recovers mail lost to throttling, transient Graph
failures or an expired subscription just as well, none of which announce themselves.

HOW ABSENCE IS DETERMINED
-------------------------
Not by subject, date or sender - by the message-id tail that the workflow puts in every
blob name. The same transform as transform.ps1 and sweep-inbox.ps1:

    last 24 chars of the Graph message id, then '/'->'_', '+'->'-', '=' dropped

A message is missing exactly when no blob in the container carries its tail. Listing the
container takes several minutes, so the tail index is cached and reused; -RefreshIndex or
an index older than -IndexMaxAgeHours forces a rebuild.

Re-enqueuing an already-archived message is harmless anyway - blob names are deterministic,
so it overwrites itself - but checking first keeps a scheduled run cheap.

SAFETY
------
Dry run unless -Execute, like sweep-inbox.ps1. Nothing is read from or written to any
mailbox; the only write is the Service Bus enqueue.
#>
param(
  [double]$LookbackHours     = 24,    # how far back to search run history for Missed events
  [double]$Margin            = 1,     # extra hours before the earliest Missed event to cover
  [double]$FloorHours        = 0,     # reconcile at least this far back even with no Missed events
  [int]$IndexMaxAgeHours     = 6,
  [switch]$RefreshIndex,
  [int]$BatchSize            = 50,
  [int]$Max                  = 20000,
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
$gh = @{ Authorization = "Bearer $graph" }

function Get-IdTail([string]$id) {
  $t = if ($id.Length -gt 24) { $id.Substring($id.Length - 24, 24) } else { $id }
  $t.Replace('/','_').Replace('+','-').Replace('=','')
}

# --- 1. when did we miss something? -------------------------------------------------------
# ARM is called directly: az.cmd is a batch file and eats the '&' between query parameters,
# which silently truncates the paged action list and would hide most of the Missed events.
$tok  = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$asub = (& $az account show --query id -o tsv)
$AH   = @{ Authorization = "Bearer $tok" }
$wf   = "https://management.azure.com/subscriptions/$asub/resourceGroups/Sharepoint1/providers/Microsoft.Logic/workflows/HTTP-Matter-On-Email-Receipt"

<#
Scanning run history costs one actions call plus one outputs fetch per run - minutes for a
few hours of traffic - and all it buys is the start of the window.

A scheduled run does not need it: -LookbackHours 0 with -FloorHours N skips the scan and
reconciles a fixed trailing window instead. That covers Missed events whether or not we
bothered to count them, and covers throttling and transient failures too. Use the scan when
you want to know how much was missed and exactly when, not as the routine path.
#>
$missed = @()
$cut = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
if ($LookbackHours -le 0) {
  Write-Host "skipping the run-history scan (-LookbackHours 0); using -FloorHours for the window"
} else {
Write-Host "scanning run history since $($cut.ToString('u')) for Missed notifications ..."
$runs = @(); $u = "$wf/runs?api-version=2016-06-01&`$top=250"
while ($u) {
  $p = Invoke-RestMethod -Uri $u -Headers $AH
  $runs += $p.value
  $oldest = $p.value | Select-Object -Last 1
  if (-not $oldest -or ([datetime]$oldest.properties.startTime).ToUniversalTime() -lt $cut) { break }
  $u = $p.nextLink
}
$runs = @($runs | Where-Object { ([datetime]$_.properties.startTime).ToUniversalTime() -ge $cut })

foreach ($r in $runs) {
  $acts = @(); $au = "$wf/runs/$($r.name)/actions?api-version=2016-06-01"
  while ($au) { $pp = Invoke-RestMethod -Uri $au -Headers $AH; $acts += $pp.value; $au = $pp.nextLink }
  $a = $acts | Where-Object name -eq 'Get_Message_JSON'
  if (-not $a) { continue }
  $o = if ($a.properties.outputsLink.uri) { Invoke-RestMethod -Uri $a.properties.outputsLink.uri } else { $a.properties.outputs }
  if ("$o" -match '"type"\s*:\s*"Missed"') {
    $missed += [pscustomobject]@{ Time = ([datetime]$r.properties.startTime).ToUniversalTime() }
  }
}
Write-Host "  Missed notifications found: $($missed.Count) (of $($runs.Count) runs scanned)"
}

$since = $null
if ($missed.Count) {
  $since = ($missed | Sort-Object Time | Select-Object -First 1).Time.AddHours(-$Margin)
}
if ($FloorHours -gt 0) {
  $floor = (Get-Date).ToUniversalTime().AddHours(-$FloorHours)
  if (-not $since -or $floor -lt $since) { $since = $floor }
}
if (-not $since) {
  Write-Host "nothing missed in the window and no -FloorHours set; nothing to reconcile."
  return
}
Write-Host "reconciling everything received since $($since.ToString('u'))"

# --- 2. which mailboxes? ------------------------------------------------------------------
# Every mailbox with a live subscription. A Missed event that cannot be traced to one of
# them is exactly the case this covers by checking all of them.
$subs = (Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/subscriptions' -Headers $gh).value
$boxes = @()
foreach ($s in $subs) {
  if ("$($s.resource)" -match '^/?users/([^/]+)/messages$') {
    $boxes += $Matches[1]
  }
}
$boxes = @($boxes | Sort-Object -Unique)
Write-Host "subscribed mailboxes: $($boxes.Count)"
if ($boxes.Count -eq 0) { throw "no message subscriptions found - refusing to run" }

# --- 3. what is already archived? ---------------------------------------------------------
$idx = Join-Path $sp 'archive-tails.txt'
$stale = $RefreshIndex -or -not (Test-Path $idx) -or
         ((Get-Date) - (Get-Item $idx).LastWriteTime).TotalHours -gt $IndexMaxAgeHours
if ($stale) {
  Write-Host "building the archive tail index (listing the container, takes a few minutes) ..."
  $dump = Join-Path $sp 'archive-blobs.txt'
  & $az storage blob list --account-name samatters --container-name matters `
      --num-results "*" --auth-mode login --query "[].name" -o tsv 2>$null | Set-Content $dump
  $names = @(Get-Content $dump)
  if ($names.Count -lt 1000) { throw "container listing returned only $($names.Count) blobs - refusing to treat that as the archive" }
  $tails = New-Object System.Collections.Generic.HashSet[string]
  foreach ($n in $names) { if ($n -match '\[([^\]]+)\]\.eml$') { [void]$tails.Add($Matches[1]) } }
  $tails | Set-Content $idx
  Write-Host "  $($names.Count) blobs -> $($tails.Count) distinct message tails"
}
$archived = New-Object System.Collections.Generic.HashSet[string]
foreach ($t in (Get-Content $idx)) { if ($t) { [void]$archived.Add($t) } }
Write-Host "archive index: $($archived.Count) message tails (built $((Get-Item $idx).LastWriteTime))"

# --- 4. Service Bus sender (identical shape to sweep-inbox.ps1) ---------------------------
$ns  = 'sharepointexchangeeventgrid.servicebus.windows.net'
$q   = 'speventgridqueue'
# sweep-inbox.ps1 reads this from %TEMP%\sbkey.txt, which is fine for a hand-run sweep and
# useless for a scheduled job - the temp directory gets cleaned and the run then fails at the
# point where it would have enqueued, after doing all the work. Fetch it from Azure, and only
# fall back to the file if that is not permitted.
$key = $null
try {
  $key = (& $az servicebus namespace authorization-rule keys list `
            -g Sharepoint1 --namespace-name SharePointExchangeEventGrid `
            -n RootManageSharedAccessKey --query primaryKey -o tsv 2>$null)
} catch { }
if (-not $key -and (Test-Path "$env:TEMP\sbkey.txt")) { $key = (Get-Content "$env:TEMP\sbkey.txt" -Raw) }
$key = "$key".Trim()
if (-not $key) { throw "no Service Bus key: az did not return one and %TEMP%\sbkey.txt is absent" }
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

# Same rule as sweep-inbox.ps1: a folder leaf that is a well-formed RSE file number is a
# matter classification a person already made. No hint is recoverable; a wrong one files
# mail under someone else's matter.
function Get-MatterHint([string]$leaf) {
  $t = "$leaf".Trim()
  if ($t -match '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$') { return $t }
  ''
}

<#
Folders whose contents are not correspondence, matching sweep-inbox.ps1.

This matters more here than it does for a sweep. The live path only ever sees "created"
notifications, so a message that was later moved to Deleted Items or Junk was archived (or
not) based on where it arrived. The reconciler instead sees mail where it sits NOW, so
without this it would archive everything a user has since binned or that spam filtering
caught - mail the live path would never have offered.
#>
$skipFolders = @('Drafts','Deleted Items','Junk Email','Outbox','Conversation History',
                 'Sync Issues','Recoverable Items','RSS Feeds','Clutter','Scheduled')

# --- 5. compare and enqueue ---------------------------------------------------------------
$stamp   = $since.ToString('yyyy-MM-ddTHH:mm:ssZ')
$total   = 0; $gap = 0; $queued = 0; $errors = 0; $skipped = 0
$report  = @()
$batch   = @()

foreach ($box in $boxes) {
  $uid = $null
  try { $uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$box`?`$select=id" -Headers $gh).id }
  catch { Write-Warning "cannot resolve $box - $($_.Exception.Message)"; $errors++; continue }

  $folderHint = @{}
  $seen = 0; $missing = 0
  $u = "https://graph.microsoft.com/v1.0/users/$uid/messages?`$filter=receivedDateTime ge $stamp" +
       "&`$select=id,subject,receivedDateTime,parentFolderId&`$top=200"
  while ($u -and $queued -lt $Max) {
    $page = $null
    for ($try = 1; $try -le 5; $try++) {
      try { $page = Invoke-RestMethod -Uri $u -Headers $gh; break }
      catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -in 429,503,504) {
          $wait = 5 * $try
          try { if ($resp.Headers.RetryAfter.Delta) { $wait = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds } } catch { }
          Start-Sleep -Seconds $wait
        } else { throw }
      }
    }
    if (-not $page) { Write-Warning "$box - giving up on a page after retries"; $errors++; break }

    foreach ($m in $page.value) {
      $seen++; $total++
      $tail = Get-IdTail $m.id
      if ($archived.Contains($tail)) { continue }
      $missing++; $gap++

      # The folder is needed twice - to exclude bins and drafts, and for the matter hint - so
      # it is resolved once and cached per mailbox. Looked up only for messages that are
      # actually missing, which keeps a scheduled run to a handful of calls.
      $hint = ''; $leaf = ''
      if ($m.parentFolderId) {
        if (-not $folderHint.ContainsKey($m.parentFolderId)) {
          try {
            $f = Invoke-RestMethod -Headers $gh -Uri "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($m.parentFolderId)?`$select=displayName"
            $folderHint[$m.parentFolderId] = [pscustomobject]@{ Leaf = "$($f.displayName)".Trim(); Hint = (Get-MatterHint $f.displayName) }
          } catch { $folderHint[$m.parentFolderId] = [pscustomobject]@{ Leaf = ''; Hint = '' } }
        }
        $leaf = $folderHint[$m.parentFolderId].Leaf
        $hint = $folderHint[$m.parentFolderId].Hint
      }
      if ($leaf -and ($skipFolders -contains $leaf)) { $missing--; $gap--; $skipped++; continue }

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
          SubscriptionId                 = 'missed-reconcile'
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

      # The full message id, not just the tail: the tail identifies a blob but cannot be
      # turned back into a Graph id, so a report carrying only tails cannot be used to go
      # and look at what was missed.
      $report += [pscustomobject]@{
        Mailbox = $box; Received = $m.receivedDateTime; Tail = $tail
        Hint = $hint; Folder = $leaf; MessageId = $m.id; Subject = "$($m.subject)"
      }
      $batch += $evt
      $queued++
      if ($batch.Count -ge $BatchSize) {
        if ($Execute) { try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ } }
        $batch = @()
      }
    }
    $u = $page.'@odata.nextLink'
  }

  if ($batch.Count -gt 0) {
    if ($Execute) { try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ } }
    $batch = @()
  }
  Write-Host ("  {0,-34} {1,6} received  {2,5} NOT archived" -f $box, $seen, $missing)
}

$csv = Join-Path $sp ("missed-reconcile-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | Export-Csv $csv -NoTypeInformation -Encoding utf8

Write-Host ""
Write-Host ("{0}: {1} messages checked, {2} missing from the archive, {3} enqueued, {5} skipped (bins/drafts), {4} errors" -f `
  $(if ($Execute) { 'EXECUTED' } else { 'DRY RUN' }), $total, $gap, $(if ($Execute) { $queued } else { 0 }), $errors, $skipped)
Write-Host "detail: $csv"
if (-not $Execute -and $gap -gt 0) { Write-Host "re-run with -Execute to enqueue them." }


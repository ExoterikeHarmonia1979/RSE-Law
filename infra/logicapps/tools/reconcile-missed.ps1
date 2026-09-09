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
Not by subject, date or sender - by the identifier the workflow puts in every blob name.
There are two, because the naming scheme changed, and a message is missing only when
NEITHER is present:

    legacy   last 24 chars of the Graph message id, '/'->'_', '+'->'-', '=' dropped
    k-token  k + 22 hex of sha256(message-id + '|' + sent-utc), from DedupTokenFunc

Everything archived before the switch carries a legacy tail; everything since carries a
k-token, as does the mailbox export - and the export's blobs are .msg, not .eml. Measured
over the whole container on 2026-09-09 (1,045,597 blobs): matching '[...].eml' alone finds
332,530 distinct identities, matching '[...].(eml|msg)' finds 750,001. A .eml-only rule was
blind to 417,471 archived messages - more than half the archive.

Checking only one scheme reports live mail as missing and re-queues it on every run - see
Resolve-TokenFuncUrl in archive-identity.ps1 for how the Function URL is found, and what
happens when it cannot be.

Listing the container takes minutes, so the index is cached and reused; -RefreshIndex or
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
  [switch]$Execute,
  # Left empty deliberately: Resolve-TokenFuncUrl below also tries the environment and Key
  # Vault. Defaulting it to $env: here would have hidden the Key Vault leg from the scheduled
  # run, which is the environment that has no environment.
  [string]$TokenFuncUrl,
  # Runs the offline negative controls and exits. Placed before every credential and
  # network call so it works on a box with no az login, like dedup-execute.py's selftest.
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

<#
Meeting traffic is excluded from the archive BY CLIENT INSTRUCTION - the firm does not want
it propagated - and transform.ps1 already refuses it, matching the substring 'eventMessage'
against the message's @odata.type. Graph returns eventMessage, eventMessageRequest or
eventMessageResponse for the three forms and no type at all for ordinary mail, so the
substring covers all three and nothing else.

The reconciler has to agree with that guard, and until now it did not. It listed calendar
items, correctly found them absent from the archive, enqueued them, and the Logic App
correctly refused them - so the same messages were reported missing and re-queued on every
run, forever. Measured on the 2026-09-09 16:34Z run: 69 of 165 reported-missing messages
(41%) had a meeting-response subject prefix, and invitations carry no prefix at all, so the
true share was higher. 13 of a sample of 40 had subjects that appear nowhere among 1.04
million blob names, which is what deliberate non-archiving looks like from outside.

The cost was never lost mail - it is wasted enqueues and a missing-count nobody can read.
The type is tested, never who is copied: an earlier From/To 'calendar' string test was 98%
false-positive because calendar@rse-law.com is routinely copied on real matter mail.
#>
function Test-IsCalendarItem($Message) {
  $t = "$($Message.'@odata.type')"
  return $t -like '*eventMessage*'
}

if ($SelfTest) {
  $fail = @()
  function Check($name, $got, $want) {
    if ($got -eq $want) { Write-Host "  ok   $name" }
    else { Write-Host "  FAIL $name (got '$got', wanted '$want')"; $script:fail += $name }
  }
  Write-Host 'calendar guard:'
  # All three derived types Graph returns for meeting traffic must be caught. transform.ps1
  # matches the substring 'eventMessage' for exactly this reason, and this has to agree with
  # it: a message the Logic App refuses but the reconciler enqueues is re-queued forever.
  Check 'eventMessage caught'         (Test-IsCalendarItem @{ '@odata.type' = '#microsoft.graph.eventMessage' })         $true
  Check 'eventMessageRequest caught'  (Test-IsCalendarItem @{ '@odata.type' = '#microsoft.graph.eventMessageRequest' })  $true
  Check 'eventMessageResponse caught' (Test-IsCalendarItem @{ '@odata.type' = '#microsoft.graph.eventMessageResponse' }) $true
  # Graph omits @odata.type for an ordinary message, so absent must mean "not calendar".
  # Getting this backwards would skip every real message and archive nothing.
  Check 'absent type is ordinary mail' (Test-IsCalendarItem @{ subject = 'Re: 100.079 discovery' })                      $false
  Check 'explicit message type passes' (Test-IsCalendarItem @{ '@odata.type' = '#microsoft.graph.message' })             $false
  # The guard tests the type, never who is copied. An earlier From/To 'calendar' string test
  # was 98% false-positive because calendar@rse-law.com is routinely copied on matter mail.
  Check 'calendar in address not caught' (Test-IsCalendarItem @{
      subject = 'MCB/EHT 100.079 - CMC/OSC re Failure to File POS'
      from    = @{ emailAddress = @{ address = 'calendar@rse-law.com' } } })                                             $false
  Write-Host ''
  if ($fail.Count) { Write-Host "$($fail.Count) control(s) misbehaved: $($fail -join ', ')"; exit 1 }
  Write-Host 'all calendar-guard controls behaved as specified.'
  exit 0
}

. "$PSScriptRoot\archive-identity.ps1"

$sp     = $PSScriptRoot
$az     = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tenant = '29b31beb-399c-4432-aa07-9258f6e46620'
$appId  = '43248a7a-1c76-40fd-91b6-57ec5f08639e'

$TokenFuncUrl = Resolve-TokenFuncUrl -Explicit $TokenFuncUrl
Write-Host ("k-token lookup: {0}" -f $(if ($TokenFuncUrl) { 'enabled' } else { 'DISABLED - legacy tails only' }))

$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$graph  = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
             client_id = $appId; scope = 'https://graph.microsoft.com/.default'
             client_secret = $secret; grant_type = 'client_credentials' }).access_token
$gh = @{ Authorization = "Bearer $graph" }

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
# Read first: an index built under a different extraction rule is stale however new it is,
# and Read-ArchiveIndex is the only thing that can tell.
$archived = Read-ArchiveIndex $idx
<#
An index older than the window is worse than no index: it reports mail as missing purely
because it was archived after the snapshot was taken.

Measured on the 19:42Z run: window 3 hours, index 1h40m old, 288 of 542 messages called
missing - and 246 of those 288 arrived AFTER the index snapshot, so the index could not have
contained them however well the pipeline worked. A 53% "loss rate" that was 85% arithmetic.
The waste is real (every run re-enqueues a few hundred already-archived messages) but the
worse cost is that it buries the real signal: the residual 42 are indistinguishable from the
noise unless you go and check.

So the index must cover the window. If its snapshot predates the window start, rebuild
regardless of -IndexMaxAgeHours; that parameter caps how OLD an index may be, which is a
different question from whether it reaches back far enough.
#>
$idxTime = if ($archived) { (Get-Item $idx).LastWriteTime.ToUniversalTime() } else { [datetime]::MinValue }
$stale = $RefreshIndex -or -not $archived -or
         ((Get-Date) - (Get-Item $idx).LastWriteTime).TotalHours -gt $IndexMaxAgeHours -or
         $idxTime -lt $since
if ($stale -and $archived -and $idxTime -lt $since) {
  Write-Host ("index snapshot {0} predates the window start {1} - rebuilding so it covers the window" -f
              $idxTime.ToString('u'), $since.ToString('u'))
}
if ($stale) {
  Write-Host "building the archive index (paged REST listing, ~100k blobs/min) ..."
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $names = @(Get-AllBlobNames -Account samatters -Container matters -Progress {
    param($n) Write-Host ("  {0:n0} blobs, {1:n0}s ..." -f $n, $sw.Elapsed.TotalSeconds)
  })
  if ($names.Count -lt 1000) { throw "container listing returned only $($names.Count) blobs - refusing to treat that as the archive" }
  $dump = Join-Path $sp 'archive-blobs.txt'
  Set-Content -Path $dump -Value $names
  $archived = Get-ArchivedIdentities $names
  Write-ArchiveIndex -Path $idx -Identities $archived
  Write-Host ("  {0:n0} blobs -> {1:n0} distinct messages in {2:n0}s" -f $names.Count, $archived.Count, $sw.Elapsed.TotalSeconds)
}
Write-Host "archive index: $($archived.Count) distinct messages (built $((Get-Item $idx).LastWriteTime))"

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
$total   = 0; $gap = 0; $queued = 0; $errors = 0; $skipped = 0; $calendar = 0
$report  = @()
$batch   = @()

foreach ($box in $boxes) {
  $uid = $null
  try { $uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$box`?`$select=id" -Headers $gh).id }
  catch { Write-Warning "cannot resolve $box - $($_.Exception.Message)"; $errors++; continue }

  $folderHint = @{}
  $seen = 0; $missing = 0
  $u = "https://graph.microsoft.com/v1.0/users/$uid/messages?`$filter=receivedDateTime ge $stamp" +
       # No @odata.type here, deliberately. Graph rejects it outright - "Term '@odata.type'
       # is not valid in a $select or $expand expression" (BadRequest) - which would fail
       # every page of every run. It does not need requesting: Graph emits @odata.type
       # automatically for a derived type, and omits it for an ordinary message, which is
       # exactly the distinction the guard tests.
       "&`$select=id,subject,receivedDateTime,parentFolderId,internetMessageId,sentDateTime&`$top=200"
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

    $kTokens = Get-KTokens -Messages $page.value -FuncUrl $TokenFuncUrl

    foreach ($m in $page.value) {
      $seen++; $total++
      # Either scheme counts as archived. Legacy names are never rewritten, so a message
      # archived before the pipeline switched is found by its tail forever; one archived
      # after is found by its token.
      $tail = Get-IdTail $m.id
      $ktok = $kTokens[$m.id]
      if ($archived.Contains($tail) -or ($ktok -and $archived.Contains($ktok))) { continue }
      $missing++; $gap++

      # Before the folder lookup, because this needs no Graph call and most of what reaches
      # here is calendar traffic. Counted separately from bins/drafts: they are skipped for
      # different reasons and one number covering both would hide how much of the residual
      # is the known-correct exclusion rather than a gap.
      if (Test-IsCalendarItem $m) { $missing--; $gap--; $calendar++; continue }

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
Write-Host ("{0}: {1} messages checked, {2} missing from the archive, {3} enqueued, {5} skipped (bins/drafts), {6} calendar (excluded by design), {4} errors" -f `
  $(if ($Execute) { 'EXECUTED' } else { 'DRY RUN' }), $total, $gap, $(if ($Execute) { $queued } else { 0 }), $errors, $skipped, $calendar)
Write-Host "detail: $csv"
if (-not $Execute -and $gap -gt 0) { Write-Host "re-run with -Execute to enqueue them." }


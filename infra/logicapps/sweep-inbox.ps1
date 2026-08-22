#requires -Version 7
<#
Feed an existing mailbox through the archive pipeline.

Replaces the "Unsorted Matters" Power Automate flow, which did the same sweep with its own
copy of the matter-matching logic, its own SharePoint site provisioning, and a client secret
pasted into the flow definition. Rather than repair 126 actions, this enumerates the mailbox
and raises one Service Bus event per message in exactly the shape Graph would send, so the
work is done by HTTP-Matter-On-Email-Receipt - the pipeline that already has managed-identity
auth, peek-lock durability, and a single matter-matching implementation.

Safe to re-run. Blob names are deterministic (matter + sanitised subject + the tail of the
Graph message id), so a message processed twice overwrites its OWN blob rather than
duplicating it. There is no "processed" marker on the mailbox, so a repeat sweep genuinely
reprocesses everything - that is the accepted trade-off for not moving or flagging anyone's
mail.

The message-id component was added 2026-08-20. Before it, the name was the subject alone,
so two DIFFERENT messages sharing a subject - every reply in a thread - collapsed onto one
blob and the archive kept only the last. A sweep run after that change writes each message
to its own path, which is the point: it recovers the thread history that earlier sweeps
silently discarded.

Expect duplicates while both generations coexist. Mail archived before the change still
sits under its old subject-only name, and this sweep writes it again under the new name;
until the old-format blobs are removed, search returns both. The old ones are the copies
WITHOUT a " [id]" suffix before .eml.

Enqueue only. Nothing is read from or written to the mailbox.
#>
param(
  [string]$Mailbox   = 'matters@rse-law.com',
  [string]$Folder    = 'Inbox',
  [int]$Max          = 1000,        # messages to enqueue this run
  [int]$Skip         = 0,           # resume point, in messages (single-folder mode only)
  [int]$BatchSize    = 100,         # Service Bus accepts a batched send
  [switch]$AllFolders,              # walk every folder, not just $Folder
  [string]$OnlyPath,                # -AllFolders: restrict to folder paths containing this
  [string]$RestrictToTails,         # file of blob id-suffixes; enqueue only those messages
  [string]$StateFile,               # -AllFolders: record finished folders so a re-run resumes
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

# The File Cabinet tree is a matter classification a person already made - folder leaves are
# matter numbers ("119.014", occasionally with a stray leading space). Anything that is not a
# well-formed RSE file number yields NO hint: no hint is recoverable, a wrong one files mail
# under someone else's matter.
function Get-MatterHint([string]$leaf) {
  $t = "$leaf".Trim()
  if ($t -match '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$') { return $t }
  ''
}

# Folders whose contents are not matter correspondence. Skipping a folder skips its children.
$skipNames = @('Drafts','Deleted Items','Junk Email','Outbox','Conversation History',
               'Sync Issues','Recoverable Items','RSS Feeds','Clutter','Scheduled')

$script:targets = @()
function Add-Folders($url, $prefix) {
  $u = $url
  while ($u) {
    $p = Invoke-RestMethod -Uri $u -Headers $gh
    foreach ($f in $p.value) {
      $leaf = "$($f.displayName)".Trim()
      if ($skipNames -contains $leaf) { continue }
      $path = if ($prefix) { "$prefix/$leaf" } else { $leaf }
      if ($f.totalItemCount -gt 0) {
        $script:targets += [pscustomobject]@{
          Id = $f.id; Path = $path; Count = $f.totalItemCount; Hint = (Get-MatterHint $leaf)
        }
      }
      if ($f.childFolderCount -gt 0) {
        Add-Folders "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($f.id)/childFolders?`$top=100" $path
      }
    }
    $u = $p.'@odata.nextLink'
  }
}

if ($AllFolders) {
  Add-Folders "https://graph.microsoft.com/v1.0/users/$uid/mailFolders?`$top=100" ''
  if ($OnlyPath) {
    $script:targets = @($script:targets | Where-Object { $_.Path -like "*$OnlyPath*" })
    Write-Host "restricted to paths containing '$OnlyPath'"
  }
  # A targeted re-run exists to apply the folder hint. A folder without one cannot change
  # any outcome - its mail would land unsorted again - so walking it is pure cost.
  if ($RestrictToTails) {
    $before = $script:targets.Count
    $script:targets = @($script:targets | Where-Object { $_.Hint -ne '' })
    Write-Host "skipped $($before - $script:targets.Count) folders with no matter number (nothing to apply)"
  }
  $withHint = @($script:targets | Where-Object { $_.Hint -ne '' })
  Write-Host ("folders to sweep: {0} ({1} messages); {2} carry a matter number ({3} messages)" -f `
    $script:targets.Count, (($script:targets | Measure-Object Count -Sum).Sum),
    $withHint.Count, (($withHint | Measure-Object Count -Sum).Sum))
} else {
  $script:targets = @([pscustomobject]@{ Id = $Folder; Path = $Folder; Count = -1; Hint = '' })
}

<#
Re-send only specific messages, identified by the suffix in their blob name.

Blob names end in " [<tail>].eml" where <tail> is what Email_Blob_Name builds from the Graph
message id. Reproducing that transform here lets a blob be mapped back to the message that
produced it, so a targeted re-run can cover exactly the mail a bug mis-filed instead of
re-processing the whole File Cabinet - roughly a tenth of the work.

This MUST match transform.ps1's $idTail exactly. If that changes, change this:
    last 24 chars, then '/'->'_', '+'->'-', '=' dropped
#>
function Get-IdTail([string]$id) {
  $t = if ($id.Length -gt 24) { $id.Substring($id.Length - 24, 24) } else { $id }
  $t.Replace('/','_').Replace('+','-').Replace('=','')
}
$tailSet = $null
if ($RestrictToTails) {
  if (-not (Test-Path $RestrictToTails)) { throw "no tails file at $RestrictToTails" }
  $tailSet = @{}
  foreach ($l in (Get-Content $RestrictToTails)) { if ("$l".Trim()) { $tailSet["$l".Trim()] = $true } }
  Write-Host "restricted to $($tailSet.Count) message id-suffixes"
  if ($StateFile) { Write-Host "note: -StateFile is ignored in this mode (folders are only partly covered)"; $StateFile = '' }
}

# --- resume support: a 198k-message sweep should never redo folders it already sent
$done = @{}
if ($StateFile -and (Test-Path $StateFile)) {
  foreach ($l in (Get-Content $StateFile)) { if ("$l".Trim()) { $done["$l".Trim()] = $true } }
  Write-Host "resuming: $($done.Count) folders already completed"
}

# --- walk, oldest first so the backlog drains in arrival order
$seen = 0; $queued = 0; $errors = 0; $batch = @(); $fIndex = 0
# Blob names are unique per message only if the id tail is. Two messages in the SAME matter
# with the same tail AND the same subject would collide onto one blob - the exact defect the
# suffix was added to fix. Counting them here costs nothing on a walk we are doing anyway.
$tailsSeen = @{}; $tailCollisions = 0; $idsSeen = @{}; $pagingDupes = 0
foreach ($t in $script:targets) {
  $fIndex++
  if ($queued -ge $Max) { break }
  if ($done.ContainsKey($t.Id)) { continue }

  $url = "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($t.Id)/messages" +
         "?`$select=id&`$top=999&`$orderby=receivedDateTime asc"
  $fQueued = 0
  while ($url) {
    $page = Invoke-RestMethod -Uri $url -Headers $gh
    foreach ($m in $page.value) {
      $seen++
      if (-not $AllFolders -and $seen -le $Skip) { continue }
      if ($queued -ge $Max) { break }
      # Deduplicate by message id FIRST. Graph paging hands back the same message more than
      # once - no stable sort, live folder - and counting those as collisions reported 3,327
      # of them where a dedup'd re-measure found exactly zero. A false alarm here would send
      # someone rewriting a naming scheme that is fine.
      $mTail = Get-IdTail $m.id
      if ($idsSeen.ContainsKey($m.id)) { $pagingDupes++ }
      else {
        $idsSeen[$m.id] = $true
        $tKey = "$($t.Hint)|$mTail"
        if ($tailsSeen.ContainsKey($tKey)) { $tailCollisions++ } else { $tailsSeen[$tKey] = $true }
      }
      if ($tailSet -and -not $tailSet.ContainsKey($mTail)) { continue }

      $resource = "Users/$uid/Messages/$($m.id)"
      # Shaped to match a real Graph change notification; the workflow reads
      # data.ResourceData['@odata.id'] and data.ResourceData.Id from this.
      # MatterHint is ours and is absent from real notifications - the workflow uses it
      # only when subject matching has already failed.
      $evt = [ordered]@{
        type            = 'Microsoft.Graph.MessageCreated'
        specversion     = '1.0'
        source          = "/tenants/$tenant/applications/$appId"
        subject         = $resource
        id              = [guid]::NewGuid().ToString()
        time            = (Get-Date).ToUniversalTime().ToString('o')
        datacontenttype = 'application/json'
        data            = [ordered]@{
          SubscriptionId                 = 'mailbox-sweep'
          SubscriptionExpirationDateTime = (Get-Date).ToUniversalTime().AddDays(1).ToString('o')
          ChangeType                     = 'created'
          Resource                       = $resource
          MatterHint                     = $t.Hint
          ResourceData                   = [ordered]@{
            '@odata.type' = '#Microsoft.Graph.Message'
            '@odata.id'   = $resource
            'Id'          = $m.id
          }
        }
      } | ConvertTo-Json -Depth 8 -Compress

      $batch += $evt
      $queued++; $fQueued++

      if ($batch.Count -ge $BatchSize) {
        if ($Execute) {
          try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ }
        }
        $batch = @()
      }
    }
    if ($queued -ge $Max) { break }
    $url = $page.'@odata.nextLink'
  }

  # Flush before recording the folder as done, or the state file would claim messages that
  # were never sent and a resume would skip them for good.
  if ($batch.Count -gt 0 -and $Execute) {
    try { Send-Batch $batch } catch { Write-Warning $_.Exception.Message; $errors++ }
  }
  $batch = @()

  $complete = ($queued -lt $Max)
  if ($StateFile -and $Execute -and $complete) { Add-Content -Path $StateFile -Value $t.Id }
  if ($AllFolders) {
    Write-Host ("  [{0}/{1}] {2,-46} queued {3,5}  total {4}{5}" -f `
      $fIndex, $script:targets.Count, $t.Path, $fQueued, $queued,
      $(if ($t.Hint) { "  hint=$($t.Hint)" } else { '' }))
  } else {
    Write-Host "  queued $queued / $Max"
  }
}

Write-Host ("{0}: scanned={1} queued={2} errors={3}{4}" -f `
  $(if ($Execute) { 'EXECUTED' } else { 'DRY RUN' }), $seen, $queued, $errors,
  $(if ($AllFolders) { '' } else { "  (resume with -Skip $($Skip + $queued))" }))
Write-Host ("id-tail uniqueness: {0} distinct (matter,tail) pairs over {1} distinct messages; COLLISIONS={2} (paging duplicates excluded: {3})" -f `
  $tailsSeen.Count, $idsSeen.Count, $tailCollisions, $pagingDupes)
if ($tailCollisions -gt 0) {
  Write-Host "  a collision means two messages in one matter can share a blob name - the suffix is too short" -ForegroundColor Yellow
}


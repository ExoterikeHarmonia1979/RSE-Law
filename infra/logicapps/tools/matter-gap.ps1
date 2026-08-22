#requires -Version 7
<#
Why does Outlook find N messages for a matter while the archive holds far fewer?

Searches the matters mailbox exactly the way Outlook does ($search covers subject, body and
attachment text) using the same app-only identity sweep-inbox.ps1 uses, then decomposes the
gap into causes that can be counted separately:

  - which FOLDER each message lives in   -> the sweep only ever walked Inbox
  - matter number in the SUBJECT or not  -> the archive matches on subject alone
  - distinct subjects                    -> thread collapse under the old blob naming

Read-only. Nothing is written to or moved in the mailbox.
#>
param(
  [Parameter(Mandatory)][string]$Matter,
  [string]$Mailbox = 'matters@rse-law.com'
)
$ErrorActionPreference = 'Stop'
$az     = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tenant = '29b31beb-399c-4432-aa07-9258f6e46620'
$appId  = '43248a7a-1c76-40fd-91b6-57ec5f08639e'

$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$graph  = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
             client_id = $appId; scope = 'https://graph.microsoft.com/.default'
             client_secret = $secret; grant_type = 'client_credentials' }).access_token
$gh = @{ Authorization = "Bearer $graph"; ConsistencyLevel = 'eventual' }
$uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$Mailbox`?`$select=id" -Headers $gh).id

# --- folder map (display names, recursively)
$folders = @{}
function Map-Folders($parentUrl, $prefix) {
  $u = $parentUrl
  while ($u) {
    $p = Invoke-RestMethod -Uri $u -Headers $gh
    foreach ($f in $p.value) {
      $name = if ($prefix) { "$prefix/$($f.displayName)" } else { $f.displayName }
      $folders[$f.id] = $name
      if ($f.childFolderCount -gt 0) {
        Map-Folders "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($f.id)/childFolders?`$top=100" $name
      }
    }
    $u = $p.'@odata.nextLink'
  }
}
Map-Folders "https://graph.microsoft.com/v1.0/users/$uid/mailFolders?`$top=100" ''
Write-Host "mailbox folders mapped: $($folders.Count)"

# --- search the whole mailbox, as Outlook does
$msgs = @()
$u = "https://graph.microsoft.com/v1.0/users/$uid/messages?`$search=`"$Matter`"&`$top=100&`$select=subject,parentFolderId,receivedDateTime,hasAttachments,isDraft"
while ($u) {
  $p = Invoke-RestMethod -Uri $u -Headers $gh
  $msgs += $p.value
  $u = $p.'@odata.nextLink'
  if ($msgs.Count -ge 2000) { break }
}
Write-Host "`nMAILBOX: $($msgs.Count) messages mention '$Matter' (subject, body or attachment)`n"

Write-Host "by folder:"
$g = @($msgs | Group-Object parentFolderId | Sort-Object Count -Descending)
$g | Select-Object -First 12 | ForEach-Object {
  $n = if ($folders.ContainsKey($_.Name)) { $folders[$_.Name] } else { "<unmapped $($_.Name.Substring(0,12))...>" }
  "  {0,5}  {1}" -f $_.Count, $n
}
if ($g.Count -gt 12) { "  ...and $($g.Count - 12) more folders totalling $((($g | Select-Object -Skip 12) | Measure-Object Count -Sum).Sum)" }
"  ----- groups=$($g.Count) sum=$((($g | Measure-Object Count -Sum).Sum)) of $($msgs.Count) messages"

$inSubject = @($msgs | Where-Object { "$($_.subject)" -like "*$Matter*" })
Write-Host "`nmatter number appears in:"
"  {0,5}  the SUBJECT      (archive can file these)" -f $inSubject.Count
"  {0,5}  body/attachment only (archive files these as Unsorted)" -f ($msgs.Count - $inSubject.Count)

$subjects = @($msgs | ForEach-Object { "$($_.subject)".Trim() } | Where-Object { $_ -ne '' })
$distinct = @($subjects | Sort-Object -Unique)
$normalised = @($subjects | ForEach-Object {
  $s = $_
  while ($s -match '^\s*(RE|FW|FWD|Re|Fw|Fwd|AW|Automatic reply)\s*:\s*') { $s = $s -replace '^\s*(RE|FW|FWD|Re|Fw|Fwd|AW|Automatic reply)\s*:\s*','' }
  ($s -replace '[^A-Za-z0-9]','').ToLower()
} | Sort-Object -Unique)
Write-Host "`nthread shape:"
"  {0,5}  messages" -f $msgs.Count
"  {0,5}  distinct subject lines   <- the most the OLD naming could ever store" -f $distinct.Count
"  {0,5}  distinct conversations   (RE:/FW: stripped)" -f $normalised.Count

$inboxIds = @($folders.GetEnumerator() | Where-Object { $_.Value -eq 'Inbox' } | ForEach-Object { $_.Key })
$inInbox = @($msgs | Where-Object { $inboxIds -contains $_.parentFolderId })
Write-Host "`nsweep reachability (sweep-inbox.ps1 walks Inbox only, non-recursively):"
"  {0,5}  in Inbox itself      -> swept" -f $inInbox.Count
"  {0,5}  elsewhere            -> NEVER swept" -f ($msgs.Count - $inInbox.Count)
$inboxAndSubject = @($inInbox | Where-Object { "$($_.subject)" -like "*$Matter*" })
"  {0,5}  in Inbox AND matter in subject -> filed under $Matter" -f $inboxAndSubject.Count


#requires -Version 7
<#
How many messages would actually overwrite each other?

The (matter,tail) collision count is an upper bound: the blob name is subject + tail, so two
messages only land on the same blob if they share BOTH. That matters because same-subject is
the normal case inside a matter - it is what a thread is - so the two are not independent.

This reconstructs the real blob name per message and counts genuine duplicates, over the
largest folders (which dominate the corpus).
#>
param([int]$TopFolders = 25, [string]$Mailbox = 'matters@rse-law.com')
$ErrorActionPreference = 'Stop'
$az     = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tenant = '29b31beb-399c-4432-aa07-9258f6e46620'
$appId  = '43248a7a-1c76-40fd-91b6-57ec5f08639e'
$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$graph  = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
             client_id=$appId; scope='https://graph.microsoft.com/.default'
             client_secret=$secret; grant_type='client_credentials' }).access_token
$gh  = @{ Authorization = "Bearer $graph" }
$uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$Mailbox`?`$select=id" -Headers $gh).id

function Get-IdTail([string]$id) {
  $t = if ($id.Length -gt 24) { $id.Substring($id.Length - 24, 24) } else { $id }
  $t.Replace('/','_').Replace('+','-').Replace('=','')
}
# mirrors San() + the 150 cap in transform.ps1
function Get-BlobStem([string]$subject) {
  $s = "$subject"
  foreach ($c in @('\','/',':','*','?','"','<','>','|')) { $s = $s.Replace($c,'_') }
  $s = [regex]::Replace($s, '[\x00-\x1F\x7F]', '_')
  if ($s.Length -gt 150) { $s = $s.Substring(0,150) }
  $s.Trim()
}

$script:folders = @()
function Walk($url,$prefix){
  $u=$url
  while($u){
    $p = Invoke-RestMethod -Uri $u -Headers $gh
    foreach($f in $p.value){
      $leaf = "$($f.displayName)".Trim()
      $path = if($prefix){"$prefix/$leaf"}else{$leaf}
      if($leaf -match '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$' -and $f.totalItemCount -gt 0){
        $script:folders += [pscustomobject]@{ Id=$f.id; Path=$path; Matter=$leaf; Count=$f.totalItemCount }
      }
      if($f.childFolderCount -gt 0){ Walk "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($f.id)/childFolders?`$top=100" $path }
    }
    $u=$p.'@odata.nextLink'
  }
}
Walk "https://graph.microsoft.com/v1.0/users/$uid/mailFolders?`$top=100" ''
$targets = @($script:folders | Sort-Object Count -Descending | Select-Object -First $TopFolders)
Write-Host ("checking the {0} largest matter folders ({1} messages)" -f $targets.Count, (($targets | Measure-Object Count -Sum).Sum))

# Graph paging can hand back the same message more than once - there is no stable sort here
# and the folder is live. Counting those as collisions would invent a data-loss problem that
# does not exist, so every message is deduplicated by id FIRST and only distinct messages are
# compared.
$totalMsgs = 0; $pagingDupes = 0; $dupBlob = 0; $dupTail = 0; $examples = @()
foreach($t in $targets){
  $names = @{}; $tails = @{}; $ids = @{}
  $u = "https://graph.microsoft.com/v1.0/users/$uid/mailFolders/$($t.Id)/messages?`$select=id,subject&`$top=100"
  while($u){
    $p = Invoke-RestMethod -Uri $u -Headers $gh
    foreach($m in $p.value){
      if($ids.ContainsKey($m.id)){ $pagingDupes++; continue }
      $ids[$m.id] = $true
      $totalMsgs++
      $tail = Get-IdTail $m.id
      if($tails.ContainsKey($tail)){ $dupTail++ } else { $tails[$tail] = $true }
      $blob = (Get-BlobStem $m.subject) + " [$tail].eml"
      if($names.ContainsKey($blob)){
        $dupBlob++
        if($examples.Count -lt 5){ $examples += "$($t.Matter): $blob" }
      } else { $names[$blob] = $true }
    }
    $u = $p.'@odata.nextLink'
  }
}
Write-Host "same message returned twice by paging (excluded): $pagingDupes"
Write-Host ""
Write-Host "messages examined            : $totalMsgs"
Write-Host "id-tail collisions in matter : $dupTail"
Write-Host "ACTUAL blob-name collisions  : $dupBlob   <- messages that would overwrite each other"
if($examples){ Write-Host "examples:"; $examples | ForEach-Object { Write-Host "  $_" } }

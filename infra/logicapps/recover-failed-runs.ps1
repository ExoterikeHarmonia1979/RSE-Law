#requires -Version 7
<#
Recover the emails behind failed runs by re-enqueueing their trigger payloads.

Why not `resubmit`: resubmit replays a run through its ORIGINAL trigger, and that
trigger ("When_a_message_is_received_in_a_queue_(auto-complete)") no longer exists
- it was replaced by the peek-lock variant. Re-enqueueing the Service Bus payload
instead puts each message back through the normal path, so it also picks up the
peek-lock durability guarantees.

Safe to re-run: blob names are deterministic (matter + sanitised subject), so a
message processed twice overwrites its own blob rather than duplicating it.
#>
param(
  [datetime]$Before = '2026-08-08T21:14:00Z',   # failures predating the fix window
  [datetime]$After  = '2026-08-08T18:00:00Z',
  [int]$MaxPages    = 20,
  [switch]$Execute                               # dry-run unless set
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web

$sub='66268ff4-4804-4950-bfba-07b41a8660ec'; $rg='Sharepoint1'
$wf='HTTP-Matter-On-Email-Receipt'
$base="https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$wf"
$az="$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$h=@{ Authorization = "Bearer $(& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)" }

# ---- collect failed runs in the window
$url="$base/runs?api-version=2016-06-01&`$top=250"; $all=@(); $p=0
while($url -and $p -lt $MaxPages){
  $r=Invoke-RestMethod -Uri $url -Headers $h; $all+=$r.value; $url=$r.nextLink; $p++
}
$targets=@($all | Where-Object {
  $_.properties.status -eq 'Failed' -and
  ([datetime]$_.properties.startTime).ToUniversalTime() -lt $Before.ToUniversalTime() -and
  ([datetime]$_.properties.startTime).ToUniversalTime() -gt $After.ToUniversalTime()
})
Write-Host "pages=$p  runs=$($all.Count)  failed-in-window=$($targets.Count)"

# ---- Service Bus sender
$ns='sharepointexchangeeventgrid.servicebus.windows.net'; $q='speventgridqueue'
$key=(Get-Content "$env:TEMP\sbkey.txt" -Raw).Trim()
$enc=[System.Web.HttpUtility]::UrlEncode("https://$ns/$q")
$exp=[int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s))+7200
$hm=New-Object System.Security.Cryptography.HMACSHA256(,[Text.Encoding]::UTF8.GetBytes($key))
$sig=[Convert]::ToBase64String($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes("$enc`n$exp")))
$sbH=@{ Authorization = "SharedAccessSignature sr=$enc&sig=$([System.Web.HttpUtility]::UrlEncode($sig))&se=$exp&skn=RootManageSharedAccessKey" }

$seen=@{}; $sent=0; $dup=0; $noPayload=0; $err=0
foreach($t in $targets){
  $lnk=$t.properties.trigger.outputsLink.uri
  if(-not $lnk){ $noPayload++; continue }
  try { $o=Invoke-RestMethod -Uri $lnk } catch { $noPayload++; continue }
  $cd=$o.body.ContentData
  if(-not $cd){ $noPayload++; continue }
  $json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cd))
  # dedupe on the Graph resource path, which identifies the mail item
  $key2 = try { ($json | ConvertFrom-Json).subject } catch { $json }
  if($seen.ContainsKey($key2)){ $dup++; continue }
  $seen[$key2]=$true
  if(-not $Execute){ $sent++; continue }
  try {
    Invoke-WebRequest -Method Post -Uri "https://$ns/$q/messages" -Headers $sbH `
      -ContentType 'application/json;type=entry;charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
    $sent++
  } catch { Write-Warning $_.Exception.Message; $err++; if($err -gt 10){ break } }
}
Write-Host ("{0}: enqueued={1} duplicates-skipped={2} no-payload={3} errors={4}" -f ($(if($Execute){'EXECUTED'}else{'DRY RUN'})),$sent,$dup,$noPayload,$err)

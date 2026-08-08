#requires -Version 7
# Move messages from speventgridqueue/$deadletterqueue back onto the main queue.
# Destructive-read from DLQ + send to main, one at a time, so a crash loses at most
# the single in-flight message (which is still visible in the run history).
param([int]$Max = 1000, [switch]$WhatIf)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web

$ns   = 'sharepointexchangeeventgrid.servicebus.windows.net'
$q    = 'speventgridqueue'
$key  = (Get-Content "$env:TEMP\sbkey.txt" -Raw).Trim()
$kn   = 'RootManageSharedAccessKey'

function Tok($path){
  $enc=[System.Web.HttpUtility]::UrlEncode("https://$ns/$path")
  $exp=[int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s))+3600
  $h=New-Object System.Security.Cryptography.HMACSHA256(,[Text.Encoding]::UTF8.GetBytes($key))
  $sig=[Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes("$enc`n$exp")))
  "SharedAccessSignature sr=$enc&sig=$([System.Web.HttpUtility]::UrlEncode($sig))&se=$exp&skn=$kn"
}
$dlqPath = "$q/`$deadletterqueue"
$hDlq  = @{ Authorization = (Tok $dlqPath) }
$hMain = @{ Authorization = (Tok $q) }

$moved = 0; $failed = 0
for ($i = 0; $i -lt $Max; $i++) {
  # peek-lock so nothing is destroyed until the resend is confirmed
  try {
    $r = Invoke-WebRequest -Method Post -Uri "https://$ns/$dlqPath/messages/head?timeout=5" -Headers $hDlq -ErrorAction Stop
  } catch { break }
  if ($r.StatusCode -eq 204) { break }

  $bp   = $r.Headers['BrokerProperties']; if ($bp -is [array]) { $bp = $bp[0] }
  $body = $r.Content                      # byte[]
  $loc  = $r.Headers['Location'];          if ($loc -is [array]) { $loc = $loc[0] }
  $msgId = ($bp | ConvertFrom-Json).MessageId

  if ($WhatIf) {
    Write-Host "would replay $msgId ($($body.Length) bytes)"
    Invoke-WebRequest -Method Put -Uri $loc -Headers $hDlq | Out-Null   # unlock, leave in place
    $moved++; continue
  }

  try {
    Invoke-WebRequest -Method Post -Uri "https://$ns/$q/messages" -Headers $hMain `
      -ContentType 'application/octet-stream' -Body $body -ErrorAction Stop | Out-Null
    # only now remove it from the DLQ
    Invoke-WebRequest -Method Delete -Uri $loc -Headers $hDlq -ErrorAction Stop | Out-Null
    $moved++
  } catch {
    Write-Warning "replay failed for ${msgId}: $($_.Exception.Message)"
    try { Invoke-WebRequest -Method Put -Uri $loc -Headers $hDlq | Out-Null } catch {}
    $failed++
    if ($failed -gt 5) { break }
  }
}
Write-Host "replayed=$moved failed=$failed"

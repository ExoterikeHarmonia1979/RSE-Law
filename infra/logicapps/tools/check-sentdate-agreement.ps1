#requires -Version 7
<#
Does Graph's sentDateTime match the Date: header?

Every k-token in the archive was derived from the Date: header inside the message. The
sweeps want to compute tokens from Graph's sentDateTime instead, because it arrives free
in a $select they already issue and fetching each message's MIME would not be affordable.

That substitution is only sound if the two agree. This measures it rather than assuming
it. Read-only: only $select and $value (Range-limited to 64 KB) GET calls are made. No
blob write, no Graph write, no message modification.

Auth: az account get-access-token does not reliably carry mail-read scope for
matters@rse-law.com from this box's user login. Use the client-credentials app
registration that sweep-older-mail.ps1 already relies on for the same mailbox.
#>
param(
  [string]$Mailbox = 'matters@rse-law.com',
  [int]$Sample = 200
)
$ErrorActionPreference = 'Stop'
# Plain text, no ANSI: if anything ever does throw uncaught, PowerShell's colorized error
# view wraps and re-wraps the offending line per terminal column, which can blow up a short
# message into megabytes of output. Defense in depth on top of the per-message try/catch
# below, which already keeps exception content out of any output.
try { $PSStyle.OutputRendering = 'PlainText' } catch {}

$az     = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tenant = '29b31beb-399c-4432-aa07-9258f6e46620'
$appId  = '43248a7a-1c76-40fd-91b6-57ec5f08639e'

$secret = (& $az keyvault secret show --vault-name kv-rse-graphsubs --name GraphSubClientSecret --query value -o tsv)
$graph  = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
             client_id = $appId; scope = 'https://graph.microsoft.com/.default'
             client_secret = $secret; grant_type = 'client_credentials' }).access_token
$gh  = @{ Authorization = "Bearer $graph" }
$uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$Mailbox`?`$select=id" -Headers $gh).id

$url = "https://graph.microsoft.com/v1.0/users/$uid/messages" +
       "?`$select=id,internetMessageId,sentDateTime&`$top=$([Math]::Min($Sample,999))"
$page = Invoke-RestMethod -Headers $gh -Uri $url

$agree = 0; $differ = 0; $noHeader = 0; $deltas = @()
$n = 0
$total0 = $page.value.Count
Write-Host "fetched $total0 messages; comparing sentDateTime to Date: header..."

function Show-Progress {
  if ($n % 20 -eq 0 -or $n -eq $total0) {
    Write-Host ("progress: {0}/{1}  agree={2} differ={3} noHeader={4}" -f $n, $total0, $agree, $differ, $noHeader)
  }
}

foreach ($m in $page.value) {
  $n++
  # Never let any exception's .Message reach output: .NET format/parse exceptions embed the
  # offending value, and that value can be message content. Only exception *type names* are
  # logged, and only counts are ever reported.
  try {
    # $value is the raw MIME. Only the header block is needed, so ask for the first 64 KB.
    $mime = Invoke-WebRequest -Headers ($gh + @{ Range = 'bytes=0-65535' }) `
              -Uri "https://graph.microsoft.com/v1.0/users/$uid/messages/$($m.id)/`$value" `
              -UseBasicParsing

    # Invoke-WebRequest -UseBasicParsing does not reliably hand back .Content as byte[] -
    # depending on the response Content-Type it can already be a decoded [string]. Handle
    # both, and cap at 64 KB regardless of what the server actually honored on Range, so a
    # server that ignores Range never lets a whole message (attachments included) into memory
    # or into a regex.
    $raw = $mime.Content
    $bytes = if ($raw -is [byte[]]) { $raw } else { [Text.Encoding]::UTF8.GetBytes([string]$raw) }
    if ($bytes.Length -gt 65536) { $bytes = $bytes[0..65535] }
    $text = [Text.Encoding]::ASCII.GetString($bytes)

    # Bounded capture group: a real Date: header value is a few dozen characters. Capping it
    # means a malformed or unexpected match can never pull a large blob into $hdr.
    $hdr = [regex]::Match($text, '(?im)^Date:\s*(.{0,120}?)\s*$')
    if (-not $hdr.Success) { $noHeader++; Show-Progress; continue }

    $fromHeader = ([datetimeoffset]::Parse($hdr.Groups[1].Value)).ToUniversalTime()
    $fromGraph = ([datetimeoffset]$m.sentDateTime).ToUniversalTime()

    # To the second, which is the precision the token uses.
    $d = [Math]::Abs(($fromHeader - $fromGraph).TotalSeconds)
    if ($d -lt 1) { $agree++ } else { $differ++; $deltas += [int]$d }
  } catch {
    $noHeader++
    Write-Host ("  (skipped one: {0})" -f $_.Exception.GetType().Name)
  }
  Show-Progress
}

$total = $agree + $differ
Write-Host ""
Write-Host "sampled            : $($page.value.Count)"
Write-Host "comparable         : $total"
Write-Host "no usable header   : $noHeader"
if ($total -gt 0) {
  Write-Host ("agree to the second: {0} ({1:N1}%)" -f $agree, (100*$agree/$total))
  Write-Host ("differ             : {0}" -f $differ)
  if ($deltas.Count) {
    Write-Host ("  deltas seconds   : min {0}, median {1}, max {2}" -f `
      ($deltas | Measure-Object -Minimum).Minimum,
      ($deltas | Sort-Object)[[int]($deltas.Count/2)],
      ($deltas | Measure-Object -Maximum).Maximum)
  }
}
Write-Host ""
Write-Host "Read-only. Nothing was written."

<#
How the archive names mail, and how a predictor script asks for that name.

Dot-source this; do not copy it. Same pattern as deploy.ps1 dot-sourcing drift.ps1.

WHY THIS FILE EXISTS
--------------------
These functions were byte-identical copies in reconcile-missed.ps1, sweep-older-mail.ps1 and
sweep-inbox.ps1. Get-IdTail is four lines of string surgery and could survive that. Get-KTokens
could not: it carries an HTTP call, a chunk size, a URL-composition rule and an error policy,
and nothing tested that the three stayed the same. Drift in it does not throw - it makes a
sweep quietly stop recognising archived mail and re-queue it, which nobody is watching for.

The archive has used two naming schemes:

  legacy   [<24-char tail of the Graph message id>].eml
  k-token  [k<22 hex of sha256(message-id + '|' + sent-utc)>].eml   (and .msg, from the ingest)

The Graph message id is store- and folder-scoped, so the legacy name changed per recipient
mailbox and per retention move - one message, many blobs. The k-token is derived from the
message itself and does not. New mail is named by the k-token; everything archived before the
switch still carries a legacy tail, so a predictor must check BOTH.
#>

function Get-IdTail([string]$id) {
  $t = if ($id.Length -gt 24) { $id.Substring($id.Length - 24, 24) } else { $id }
  $t.Replace('/','_').Replace('+','-').Replace('=','')
}

<#
Where the k-token Function lives.

Order: an explicit -TokenFuncUrl beats the environment, which beats Key Vault. The Key Vault
leg is what makes this work unattended: RSE-Archive-Reconcile runs under Task Scheduler, which
does not inherit an interactive session's environment, so DEDUP_TOKEN_FUNC_URL was never set
for it. The scheduled run then silently matched legacy names only - against a container where
new mail is k-token named - and judged every recent message missing.

Returns $null when it finds nothing, having said so. Callers degrade to legacy-only matching;
they must not die, but they must not be quiet about it either.
#>
function Resolve-TokenFuncUrl {
  param([string]$Explicit, [string]$Vault = 'kv-rse-graphsubs', [string]$Secret = 'DedupTokenFuncUrl')

  if ($Explicit)                  { return $Explicit }
  if ($env:DEDUP_TOKEN_FUNC_URL)  { return $env:DEDUP_TOKEN_FUNC_URL }

  $az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
  try {
    $v = (& $az keyvault secret show --vault-name $Vault --name $Secret --query value -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() }
  } catch { }

  Write-Warning ("no k-token Function URL: -TokenFuncUrl unset, `$env:DEDUP_TOKEN_FUNC_URL unset, " +
                 "and $Vault/$Secret unreadable. Falling back to LEGACY-TAIL MATCHING ONLY - mail " +
                 "archived under a k-token name will be reported missing and re-queued.")
  return $null
}

<#
The k-token for a batch of messages, from the Function that owns the rule.

Deliberately not reimplemented here. The token exists in exactly one place - a PowerShell
copy that drifted by one character would not throw, it would quietly stop recognising
archived mail and re-upload it.

sentDateTime is Graph's record rather than the Date: header every existing token came from.
That substitution is safe HERE and nowhere else: a wrong token makes this script think a
message is missing, it re-queues it, and the pipeline archives it under the authoritative
token - the same name it already has - and overwrites. Wrong costs bandwidth, not a
duplicate. See the spec's "The sweeps get the cheap route the pipeline cannot have".
#>
function Get-KTokens {
  param([array]$Messages, [string]$FuncUrl)
  if (-not $Messages.Count) { return @{} }
  if (-not $FuncUrl) {
    # This was the one silent path in this function. An empty URL is not "nothing to do";
    # it is the whole k-token half of the check being switched off.
    Write-Warning "no k-token Function URL - checking legacy tails only for $($Messages.Count) message(s)"
    return @{}
  }
  # The caller's URL carries ?code=<key>, but a value pasted into Key Vault might not.
  # Guessing wrong sends the batch to the bytes route, which parses the JSON array as MIME
  # and 422s - a silent drop to legacy-only. Pick the separator from the URL itself.
  $sep = if ($FuncUrl.Contains('?')) { '&' } else { '?' }
  $map = @{}
  for ($i = 0; $i -lt $Messages.Count; $i += 500) {
    $chunk = $Messages[$i..([Math]::Min($i + 499, $Messages.Count - 1))]
    try {
      $body = @($chunk | ForEach-Object {
        @{ id = $_.id; messageId = $_.internetMessageId; sentDateTime = $_.sentDateTime }
      }) | ConvertTo-Json -Depth 4 -AsArray
      $res = Invoke-RestMethod -Method Post -Uri "$FuncUrl${sep}from=fields" `
               -ContentType 'application/json' -Body $body -TimeoutSec 120
      foreach ($r in $res) { if ($r.token) { $map[$r.id] = $r.token } }
    } catch {
      # No token means this batch falls back to legacy-tail matching only, which is how
      # the script behaved before. Never fatal.
      Write-Warning "token service unavailable for a batch of $($chunk.Count): $($_.Exception.Message)"
    }
  }
  return $map
}

<#
Every blob name in a container, as a paged REST listing.

Replaces `az storage blob list --num-results "*"`, which took over an hour on samatters/matters
and got RSE-Archive-Reconcile killed by its own PT1H ExecutionTimeLimit every run for 16 hours -
mid-listing, so the wrapper's catch never ran and the log just stopped with no error. The CLI
form pages the same REST API but materialises every blob's full property set through Python
before --query throws all but the name away. This asks for names and walks NextMarker: same
completeness, ~100k blobs a minute.

maxresults caps a PAGE, not the result set, so unlike a literal --num-results cap nothing is
silently left behind. Bearer auth via the caller's az login - no account key is minted.
#>
function Get-AllBlobNames {
  param(
    [Parameter(Mandatory)][string]$Account,
    [Parameter(Mandatory)][string]$Container,
    [string]$Prefix = '',
    [scriptblock]$Progress
  )
  $az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
  function script:NewStorageToken {
    $t = (& $az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv)
    if ($LASTEXITCODE -ne 0 -or -not $t) { throw "could not get a storage token (az exit $LASTEXITCODE) - is the az login still valid?" }
    $t.Trim()
  }

  $root  = "https://$Account.blob.core.windows.net/$Container"
  $hdr   = @{ Authorization = "Bearer $(NewStorageToken)"; 'x-ms-version' = '2021-08-06' }
  $names = New-Object System.Collections.Generic.List[string]
  $marker = ''
  $pages  = 0
  # A full listing of this container runs into the tens of minutes and the token is good for
  # about an hour, so a run that starts on an already-aged token can expire mid-listing. The
  # reindex touch run hit exactly that. Re-mint on a schedule rather than waiting for the 403.
  $tokenAge = [Diagnostics.Stopwatch]::StartNew()
  do {
    if ($tokenAge.Elapsed.TotalMinutes -ge 20) {
      $hdr['Authorization'] = "Bearer $(NewStorageToken)"
      $tokenAge.Restart()
    }
    $u = "$root`?restype=container&comp=list&maxresults=5000"
    if ($Prefix) { $u += "&prefix=$([uri]::EscapeDataString($Prefix))" }
    if ($marker) { $u += "&marker=$([uri]::EscapeDataString($marker))" }
    # Deliberately unguarded: a failed page must throw. The old code sent the listing's
    # stderr to $null, which is why an hour of failure produced no diagnosis at all.
    $resp = Invoke-WebRequest -Uri $u -Headers $hdr -UseBasicParsing
    # In PowerShell 7 .Content is already a string, but it still carries the UTF-8 BOM,
    # which a bare [xml] cast will not parse.
    $xml = [xml]($resp.Content -replace "^﻿", '')
    foreach ($b in $xml.EnumerationResults.Blobs.Blob) { $names.Add($b.Name) }
    $marker = $xml.EnumerationResults.NextMarker
    $pages++
    if ($Progress -and $pages % 20 -eq 0) { & $Progress $names.Count }
  } while ($marker)
  $names
}

<#
The set of message identities the archive already holds.

Matches BOTH schemes and BOTH extensions. .msg matters: the 401,170 blobs from the mailbox
export are named [k...].msg, and a .eml-only rule made every one of them invisible to exactly
the tool aimed at that corpus - sweep-older-mail.ps1, whose whole job is mail old enough to
have come from the export.
#>
function Get-ArchivedIdentities([string[]]$BlobNames) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($n in $BlobNames) { if ($n -match '\[([^\]]+)\]\.(eml|msg)$') { [void]$set.Add($Matches[1]) } }
  $set
}

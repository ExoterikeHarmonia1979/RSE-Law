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
    <#
    Retry a page a few times, then throw.

    "Throw on failure" was the right half of the lesson - the old code sent the listing's
    stderr to $null, so an hour of failure produced no diagnosis at all. But throwing on the
    FIRST failure is its own bug: this walk is ~210 requests over ~12 minutes, so a single
    transient blip discards the whole listing. That is not hypothetical either - the
    15:42Z scheduled run died 3.5 minutes in with "the connected party did not properly
    respond", while a bulk read was running against the same account.

    So: transient failures are absorbed, a persistent one still throws with its real error
    and the wrapper still logs "=== FAILED ===". The marker is not advanced until a page
    succeeds, so a retry re-requests the same page and no blob is skipped.

    THE RETRIED UNIT IS A PAGE, NOT A REQUEST
    -----------------------------------------
    The first version of this retry wrapped only Invoke-WebRequest, and three things could
    still walk out through the gap it left. archive-identity.selftest.ps1 pins all three.

      the re-mint    The token was re-minted inside the catch. An exception raised inside a
                     catch is not caught by its own try, so a failing re-mint left the loop,
                     left this function and killed the run - and the re-mint is itself a
                     network call (az, then AAD) on the same path that caused the retry. The
                     recovery shared the failure it was recovering from: one blip put us in
                     the catch, a second one an instant later finished the job, and the log
                     showed an az error that never mentioned the listing. It is best-effort
                     now. Failing to refresh a token that is probably still valid is not a
                     reason to discard the walk; if the token really was the problem the next
                     attempt fails again and the loop still throws the page's own error.

      the parse      Turning the body into names sat outside the retry, so a 200 carrying a
                     truncated or intercepted body was fatal on first sight. Fetch and parse
                     are one unit now - a page counts as obtained only once it has parsed.

      no page        Worst of the three, and silent. When the loop neither succeeded nor threw
                     it left $resp null, and the cast then produced an EMPTY document, because
                     [xml]'' does not throw - it returns a document with no root. Zero blobs,
                     an empty NextMarker, the do/while ends, and the function returns a SHORT
                     listing that looks like a complete one. Nothing downstream can tell the
                     difference: the reconciler diffs live mail against it and reports archived
                     mail as missing. A page must therefore look like a listing before it
                     counts - hence the EnumerationResults check, which also catches a 200 with
                     an empty body - and if the loop ever ends with nothing in hand it throws.
    #>
    $xml = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      try {
        $resp = Invoke-WebRequest -Uri $u -Headers $hdr -UseBasicParsing -TimeoutSec 120
        if (-not $resp) { throw 'the listing request returned no response' }
        # In PowerShell 7 .Content is already a string, but it still carries the UTF-8 BOM,
        # which a bare [xml] cast will not parse. Written as an escape rather than a literal
        # BOM so that re-encoding this file cannot quietly break the strip.
        $parsed = [xml]($resp.Content -replace '^\uFEFF', '')
        # An empty or non-listing body parses without complaint but carries no root, and an
        # unrecognised page must never be read as "the listing ended here".
        if (-not $parsed.EnumerationResults) { throw 'the listing page had no EnumerationResults element' }
        $xml = $parsed
        break
      }
      catch {
        # Held because the re-mint below has a catch of its own, and because this is the error
        # worth reporting: an operator needs the page failure, not a token-refresh symptom.
        $pageError = $_
        if ($attempt -eq 5) { throw $pageError }
        $wait = [Math]::Pow(2, $attempt)   # 2s, 4s, 8s, 16s
        Write-Warning ("listing page {0} failed (attempt {1}/5), retrying in {2}s: {3}" -f
                       ($pages + 1), $attempt, $wait, $pageError.Exception.Message)
        Start-Sleep -Seconds $wait
        # A long listing can outlive its token; a 403 here looks like any other failure. Best
        # effort only - see "the re-mint" above.
        try {
          $hdr['Authorization'] = "Bearer $(NewStorageToken)"
          $tokenAge.Restart()
        }
        catch {
          Write-Warning ("could not re-mint the storage token between listing attempts, " +
                         "continuing on the current one: {0}" -f $_.Exception.Message)
        }
      }
    }
    # Unreachable while the loop above throws on its last attempt, and kept anyway: this is
    # the line that decides a short listing can never be mistaken for a complete one, and it
    # is cheaper than the run that finds out otherwise.
    if (-not $xml) { throw "listing page $($pages + 1) produced no page after 5 attempts" }
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

<#
The rule this index was built under, written into the index itself.

Age is not the only way a cached index goes wrong. When the extraction rule changes, an index
built under the old rule is still FRESH and still WRONG, and nothing about it looks wrong -
it is a plausible list of plausible identities, just missing a scheme.

That is not hypothetical. The first scheduled run after this rule widened to (eml|msg) reused
a 3-hour-old index built by the previous code: 332,896 identities where the same container
yields 750,021. It judged 30 already-archived messages missing and re-enqueued them, reported
success, and would have done it again every 2 hours until the index aged out.

Bump this string whenever Get-ArchivedIdentities changes what it matches. An index whose
first line does not match is rebuilt regardless of age.
#>
$script:ArchiveIndexRule = '#rule=2 [id].(eml|msg) legacy+ktoken'

function Write-ArchiveIndex([string]$Path, $Identities) {
  @($script:ArchiveIndexRule) + @($Identities) | Set-Content -Path $Path
}

# Returns the identities, or $null when the file is absent or was built under another rule.
function Read-ArchiveIndex([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  $lines = @(Get-Content $Path)
  if (-not $lines.Count -or $lines[0] -ne $script:ArchiveIndexRule) {
    Write-Warning ("archive index at {0} was built under a different rule ({1}) - rebuilding" -f
                   $Path, $(if ($lines.Count -and $lines[0].StartsWith('#rule=')) { $lines[0] } else { 'unversioned, pre-k-token' }))
    return $null
  }
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($t in $lines[1..($lines.Count - 1)]) { if ($t) { [void]$set.Add($t) } }
  $set
}

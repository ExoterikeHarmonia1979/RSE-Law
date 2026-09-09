#requires -Version 7
<#
Offline self-test for the container listing in archive-identity.ps1.

RUN:  pwsh -NoProfile -File archive-identity.selftest.ps1
      pwsh -NoProfile -File archive-identity.selftest.ps1 -Only remint,parse

Same intent as the `selftest` subcommand in dedup-execute.py: every case that claims a check
works is paired with a negative control that proves the check can FAIL. A test that cannot
fail on the pre-fix code is worthless, so each case below names what it looked like before
the fix it pins.

Costs nothing and touches nothing: no Azure, no storage account, no az login, no mail. The
real listing is ~1500 requests over 12-19 minutes against a 1.05M-blob container, which is far
too expensive to be a test, and it cannot be made to blip on demand anyway.

THE TWO SEAMS
-------------
Get-AllBlobNames has no injection parameters, and it does not need any - PowerShell already
offers two places to lie to it:

  the request   A *function* named Invoke-WebRequest outranks the cmdlet of the same name in
                command resolution, and resolution happens per call against the dynamic scope
                chain. archive-identity.ps1 is dot-sourced, so a function defined here shadows
                the cmdlet inside Get-AllBlobNames' own body. That buys per-page control:
                which page, which attempt, fail how.

  the token     NewStorageToken shells out to "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd", and it
                reads that variable when the function runs. Point LOCALAPPDATA at a temp tree
                holding a fake az.cmd and the storage token is ours to poison mid-walk - the
                same move as selftest-token in dedup-execute.py, which poisons a credential to
                force the recovery path instead of hoping to meet it.

Start-Sleep is shadowed too, so the 2/4/8/16s backoff is asserted rather than waited out. The
whole suite runs in about a second.
#>
param(
  # Case keys to run; default is all of them.
  [string[]]$Only
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\archive-identity.ps1"

# ---------------------------------------------------------------- the fake az

$script:FakeHome = Join-Path ([IO.Path]::GetTempPath()) 'archive-identity-selftest'
$script:AzDir    = Join-Path $script:FakeHome 'AzureCLI\bin'
$script:AzFail   = Join-Path $script:AzDir 'az.fail'
New-Item -ItemType Directory -Force -Path $script:AzDir | Out-Null
# Exits non-zero while the marker file exists, which is exactly how a real az blip reaches
# NewStorageToken: a non-zero exit and no token on stdout.
Set-Content -Path (Join-Path $script:AzDir 'az.cmd') -Value @(
  '@echo off'
  'if exist "%~dp0az.fail" exit /b 1'
  'echo faketoken-%RANDOM%'
  'exit /b 0'
)
$env:LOCALAPPDATA = $script:FakeHome

function Set-AzBroken  { Set-Content -Path $script:AzFail -Value 'x' }
function Set-AzHealthy { Remove-Item -Path $script:AzFail -Force -ErrorAction SilentlyContinue }

# ------------------------------------------------------------- the fake listing

# Set per case. Called as & $Behaviour <attempt-number> <url>; returns a response or throws.
$script:Behaviour = $null
$script:Requests  = [System.Collections.Generic.List[string]]::new()
$script:Sleeps    = [System.Collections.Generic.List[int]]::new()
$script:Timeouts  = [System.Collections.Generic.List[object]]::new()

function Invoke-WebRequest {
  param([string]$Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec)
  $script:Requests.Add($Uri)
  $script:Timeouts.Add($TimeoutSec)
  & $script:Behaviour $script:Requests.Count $Uri
}

function Start-Sleep {
  param([int]$Seconds, [int]$Milliseconds)
  $script:Sleeps.Add($Seconds)
}

# A listing page as the service returns it, BOM and all. The BOM is not decoration: it is why
# the production code strips it before the [xml] cast, and a page without one would let a
# regression in that strip pass unnoticed.
function Page([string[]]$Names, [string]$NextMarker = '') {
  $blobs = ($Names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join ''
  $body  = "<?xml version=`"1.0`" encoding=`"utf-8`"?><EnumerationResults>" +
           "<Blobs>$blobs</Blobs><NextMarker>$NextMarker</NextMarker></EnumerationResults>"
  [pscustomobject]@{ Content = [char]0xFEFF + $body }
}

# The failure from the 15:42Z run, verbatim. WinHttp/Sockets surfaces it as an
# HttpRequestException out of Invoke-WebRequest, so that is what the mock raises.
function Throw-ConnectTimeout {
  throw [System.Net.Http.HttpRequestException]::new(
    'A connection attempt failed because the connected party did not properly respond after ' +
    'a period of time, or established connection failed because connected host has failed to respond.')
}

# ------------------------------------------------------------------- the runner

$script:Pass = 0
$script:Fail = 0

function It([string]$Key, [string]$Name, [scriptblock]$Body) {
  if ($Only -and $Key -notin $Only) { return }
  $script:Requests.Clear(); $script:Sleeps.Clear(); $script:Timeouts.Clear()
  Set-AzHealthy
  try {
    & $Body
    Write-Host ("  PASS  {0,-9} {1}" -f $Key, $Name) -ForegroundColor Green
    $script:Pass++
  }
  catch {
    Write-Host ("  FAIL  {0,-9} {1}" -f $Key, $Name) -ForegroundColor Red
    Write-Host ("          {0}" -f $_.Exception.Message) -ForegroundColor Red
    $script:Fail++
  }
}

function Assert([bool]$Cond, [string]$Because) {
  if (-not $Cond) { throw $Because }
}

# Runs the listing and reports how it ended, so a case can assert on a THROW without the
# throw ending the case. Distinguishing "threw" from "returned a short list" is the whole
# point of most of these.
function Walk {
  try   { return @{ threw = $false; names = @(Get-AllBlobNames -Account samatters -Container matters) } }
  catch { return @{ threw = $true;  error = $_.Exception.Message; names = @() } }
}

Write-Host "`narchive-identity listing self-test`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------- cases

It 'walk' 'a clean multi-page walk returns every name, in order, once' {
  $script:Behaviour = {
    param($n, $u)
    switch ($n) {
      1 { Page @('a[k1].eml','b[k2].eml') 'm1' }
      2 { Page @('c[k3].eml') 'm2' }
      3 { Page @('d[k4].msg') }
      default { throw "unexpected request $n" }
    }
  }
  $r = Walk
  Assert (-not $r.threw) "a clean walk threw: $($r.error)"
  Assert ((($r.names) -join ',') -eq 'a[k1].eml,b[k2].eml,c[k3].eml,d[k4].msg') `
    "wrong names or order: $($r.names -join ',')"
  Assert ($script:Requests.Count -eq 3) "expected 3 requests, made $($script:Requests.Count)"
  Assert ($script:Sleeps.Count -eq 0)   "a clean walk should never back off"
}

It 'timeout' 'every request carries a timeout' {
  # Not cosmetic. A connect that hangs rather than failing is how this task burned sixteen
  # hours: Task Scheduler killed the run at its PT1H limit, and a kill is not an exception,
  # so nothing was logged at all. An untimed request can still do that.
  $script:Behaviour = { param($n, $u) Page @('a[k1].eml') }
  $r = Walk
  Assert (-not $r.threw) "walk threw: $($r.error)"
  Assert ($script:Timeouts.Count -eq 1) "expected 1 request"
  Assert ($null -ne $script:Timeouts[0] -and [int]$script:Timeouts[0] -gt 0) `
    "request was made with no -TimeoutSec, so a hung connection has nothing to stop it"
}

It 'transient' 'a page that blips twice is retried, and no blob is skipped or doubled' {
  # The 15:42Z shape: one bad page in the middle of a long walk.
  $script:Behaviour = {
    param($n, $u)
    switch ($n) {
      1 { Page @('a[k1].eml') 'm1' }
      2 { Throw-ConnectTimeout }
      3 { Throw-ConnectTimeout }
      4 { Page @('b[k2].eml') 'm2' }
      5 { Page @('c[k3].eml') }
      default { throw "unexpected request $n" }
    }
  }
  $r = Walk
  Assert (-not $r.threw) "a transient blip lost the whole walk: $($r.error)"
  Assert ((($r.names) -join ',') -eq 'a[k1].eml,b[k2].eml,c[k3].eml') `
    "names wrong after a retry - a page was skipped or counted twice: $($r.names -join ',')"
  # The retry must re-request the SAME page. If the marker advanced past a failed page the
  # blobs behind it would be missing from the index and their mail reported unarchived.
  Assert ($script:Requests[1] -eq $script:Requests[3]) `
    "the retry did not re-request the failed page: $($script:Requests[1]) vs $($script:Requests[3])"
  Assert ((($script:Sleeps) -join ',') -eq '2,4') "backoff was $($script:Sleeps -join ',') s, expected 2,4"
}

It 'persistent' 'a page that never recovers THROWS rather than returning a short listing' {
  # The load-bearing property, and the reason none of this may be softened into a warning.
  # The reconciler diffs live mail against this listing, so a listing that is short but looks
  # complete reports archived mail as missing and re-enqueues it. Silence is the worst answer
  # available here; a thrown error only costs one run.
  $script:Behaviour = {
    param($n, $u)
    if ($n -eq 1) { return Page @('a[k1].eml') 'm1' }
    Throw-ConnectTimeout
  }
  $r = Walk
  Assert ($r.threw) "a permanently failing page returned $($r.names.Count) name(s) instead of throwing"
  Assert ($r.error -match 'connected party did not properly respond') `
    "the throw lost the real error, leaving nothing to diagnose: $($r.error)"
  Assert ($script:Sleeps.Count -eq 4) "expected 4 backoffs before giving up, saw $($script:Sleeps.Count)"
}

It 'remint' 'a token re-mint that fails mid-recovery does not end the walk' {
  # FAILED BEFORE THE FIX. The retry re-minted the storage token on every attempt, inside the
  # catch block - and an exception raised inside a catch is not caught by its own try, so it
  # left the retry loop, left Get-AllBlobNames, and killed the run. The re-mint is itself a
  # network call (az -> AAD) on the same flaky path that caused the retry, so the recovery
  # path shared the failure it was recovering from: one blip put us in the catch, a second one
  # a moment later finished the job. The page here recovers on attempt 2 and the walk still
  # died, reporting an az error that never mentions the listing.
  $script:Behaviour = {
    param($n, $u)
    switch ($n) {
      1 { Page @('a[k1].eml') 'm1' }
      2 { Set-AzBroken; Throw-ConnectTimeout }   # az goes out with the network, as it did
      3 { Set-AzHealthy; Page @('b[k2].eml') }
      default { throw "unexpected request $n" }
    }
  }
  $r = Walk
  Assert (-not $r.threw) "a failed token re-mint ended the walk: $($r.error)"
  Assert ((($r.names) -join ',') -eq 'a[k1].eml,b[k2].eml') "names wrong: $($r.names -join ',')"
}

It 'remint-die' 'a re-mint that never recovers still throws the PAGE error' {
  # Negative control for the case above: making the re-mint non-fatal must not make a real
  # failure survivable. If az stays down and the page stays down, this still has to throw -
  # and it has to throw the page's error, because that is the one that says what went wrong.
  $script:Behaviour = { param($n, $u) Set-AzBroken; Throw-ConnectTimeout }
  $r = Walk
  Assert ($r.threw) "everything failed and the walk returned $($r.names.Count) name(s) anyway"
  Assert ($r.error -match 'connected party did not properly respond') `
    "threw the re-mint's error instead of the page's: $($r.error)"
}

It 'parse' 'a page body that will not parse is retried, not fatal' {
  # FAILED BEFORE THE FIX. Only the request was inside the retry; the [xml] cast that turns
  # the body into blob names sat outside it. A 200 carrying a truncated or intercepted body
  # therefore killed the walk on the first occurrence, with a cast error rather than a
  # network one. The retried unit should be a page - fetched AND parsed.
  $script:Behaviour = {
    param($n, $u)
    switch ($n) {
      1 { Page @('a[k1].eml') 'm1' }
      2 { [pscustomobject]@{ Content = '<EnumerationResults><Blobs><Blob><Name>trunc' } }
      3 { Page @('b[k2].eml') }
      default { throw "unexpected request $n" }
    }
  }
  $r = Walk
  Assert (-not $r.threw) "an unparseable page ended the walk: $($r.error)"
  Assert ((($r.names) -join ',') -eq 'a[k1].eml,b[k2].eml') "names wrong: $($r.names -join ',')"
}

It 'parse-die' 'a page that never parses still throws' {
  # Negative control for 'parse'. Retrying a parse failure must not become swallowing one.
  $script:Behaviour = {
    param($n, $u)
    if ($n -eq 1) { return Page @('a[k1].eml') 'm1' }
    [pscustomobject]@{ Content = '<EnumerationResults><Blobs><Blob><Name>trunc' }
  }
  $r = Walk
  Assert ($r.threw) "an unparseable page returned $($r.names.Count) name(s) instead of throwing"
}

It 'noresp' 'no response can never be mistaken for the end of the listing' {
  # FAILED BEFORE THE FIX, and this is the one that would have been expensive. The loop left
  # $resp as $null when it neither succeeded nor threw; the cast then quietly produced an
  # EMPTY document, because [xml]'' does not throw - it returns a document with no root. No
  # blobs were added, NextMarker read empty, the do/while ended, and the function returned a
  # SHORT LISTING that looked like a complete one.
  #
  # Invoke-WebRequest raises its connect failures as terminating errors even under
  # $ErrorActionPreference = 'Continue' (checked, PowerShell 7.5.5), so no caller is reaching
  # this today. It is guarded anyway: the invariant "no page, no listing" costs one line, and
  # the failure it prevents is the one the reconciler cannot detect. dedup-execute.py's probe
  # carries the same guard - `if not raw` after its retry loop.
  $script:Behaviour = { param($n, $u) }   # returns nothing at all, without erroring
  $r = Walk
  Assert ($r.threw) "a page that produced no response returned $($r.names.Count) name(s) as a complete listing"
}

It 'identities' 'the listing still feeds both naming schemes and both extensions' {
  # Cheap end-to-end check that the retry rework did not disturb what the listing is FOR.
  $script:Behaviour = {
    param($n, $u)
    Page @('m/2026/x[AAAAAAAAAAAAAAAAAAAAAAAA].eml','m/2026/y[k0123456789abcdef012345].msg','m/2026/notmail.txt')
  }
  $r = Walk
  Assert (-not $r.threw) "walk threw: $($r.error)"
  $ids = Get-ArchivedIdentities $r.names
  Assert ($ids.Count -eq 2) "expected 2 identities from 3 blobs, got $($ids.Count)"
  Assert ($ids.Contains('AAAAAAAAAAAAAAAAAAAAAAAA')) 'legacy tail missing'
  Assert ($ids.Contains('k0123456789abcdef012345')) 'k-token missing'
}

# --------------------------------------------------------------------- verdict

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) `
  -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })

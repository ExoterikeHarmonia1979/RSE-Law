#requires -Version 7
<#
Take the eDiscovery export packages and land them in the blob archive.

Everything after the export is here. The export itself is attended and cannot be
scripted: Connect-IPPSSession needs an interactive window handle and the package
download runs in the browser. This picks up from the downloaded .zip files.

    unzip -> PST -> .eml (pst-to-eml.ps1) -> key (ingest-key.py) -> blob -> index row

Dry run unless -Execute, matching sweep-older-mail.ps1 and reconcile-missed.ps1.

WHAT MAKES A MESSAGE LAND IN THE RIGHT MATTER
---------------------------------------------
The folder it came from, and nothing else. A PST folder leaf that is a well-formed RSE
file number is a classification a person already made; anything else is not recoverable
and a guess would misfile. Same rule and same regex as sweep-older-mail.ps1. Messages
whose folder is not a file number go to UnsortedMatterCommunication, which is where the
live pipeline already puts them, rather than being dropped.

This means the Purview export MUST be run with "Include folder and path of the source".
Without it every message arrives in one flat folder and the matter is gone before we see
it. The script refuses to proceed if it sees no file-number folders at all.

IDEMPOTENCE
-----------
Blob names are derived from the message, not from the run, so re-running overwrites
rather than duplicating. The checkpoint file only saves time; it is not what makes a
re-run safe.

    ./ingest-run.ps1 -Source D:\exports                 # dry run: what would happen
    ./ingest-run.ps1 -Source D:\exports -Execute
    ./ingest-run.ps1 -Source D:\exports -Execute -Limit 500   # prove one batch first
#>
param(
  [Parameter(Mandatory)][string]$Source,
  [string]$Work        = (Join-Path $PSScriptRoot 'ingest-work'),
  [string]$Account     = 'samatters',
  [string]$Container   = 'matters',
  [string]$IndexPath   = (Join-Path $PSScriptRoot 'messageid-index.tsv'),
  [int]$Limit          = 0,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$py = 'python'

# Same rule as sweep-older-mail.ps1 / reconcile-missed.ps1. Keep the three in step.
function Get-MatterHint([string]$leaf) {
  $t = "$leaf".Trim()
  if ($t -match '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$') { return $t }
  ''
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$emlRoot    = Join-Path $Work 'eml'
$checkpoint = Join-Path $Work 'done.txt'
$done = @{}
if (Test-Path $checkpoint) { Get-Content $checkpoint | ForEach-Object { $done[$_] = $true } }
Write-Host "checkpoint holds $($done.Count) already-uploaded tokens"

# ---------------------------------------------------------------- 1. unpack
$zips = Get-ChildItem $Source -Filter *.zip -Recurse -ErrorAction SilentlyContinue
foreach ($z in $zips) {
  $dest = Join-Path $Work ([IO.Path]::GetFileNameWithoutExtension($z.Name))
  if (Test-Path $dest) { continue }
  Write-Host "unpacking $($z.Name)"
  # Windows' own extractor trips over the long paths Purview produces; tar is present on
  # Server 2022 and handles them.
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  & tar -xf $z.FullName -C $dest
}
# ---------------------------------------------------------------- 2. get to messages
# Purview exports either .msg files or PSTs. Prefer .msg: it needs no PST cracking, so no
# Outlook, no MAPI and no commercial library, and Azure AI Search indexes it natively.
# PST support stays for packages already exported that way.
# Look in both places. $Work holds anything this script unpacked; $Source holds the
# download itself, which is often already unpacked by hand - that is a normal way to
# arrive here, not a mistake, so it has to work.
$roots = @($Work)
if ((Resolve-Path $Source).Path -ne (Resolve-Path $Work).Path) { $roots += (Resolve-Path $Source).Path }
$msgs = @(); $psts = @()
foreach ($r in $roots) {
  $msgs += Get-ChildItem $r -Filter *.msg -Recurse -ErrorAction SilentlyContinue
  $psts += Get-ChildItem $r -Filter *.pst -Recurse -ErrorAction SilentlyContinue
}
Write-Host ".msg found: $($msgs.Count)   PSTs found: $($psts.Count)"

if ($psts) {
  foreach ($p in $psts) {
    $marker = Join-Path $emlRoot ("." + [IO.Path]::GetFileNameWithoutExtension($p.Name) + ".extracted")
    if (Test-Path $marker) { Write-Host "already extracted: $($p.Name)"; continue }
    Write-Host "extracting $($p.Name)"
    & (Join-Path $PSScriptRoot 'pst-to-eml.ps1') -Pst $p.FullName -Out $emlRoot
    New-Item -ItemType File -Force -Path $marker | Out-Null
  }
}

# .msg files are used where they lie - their folder path is the matter, so moving or
# flattening them would destroy the attribution this depends on.
$extracted = @()
if (Test-Path $emlRoot) { $extracted += Get-ChildItem $emlRoot -Filter *.eml -Recurse }
$extracted += $msgs
$emls = $extracted
Write-Host "messages to process: $($emls.Count)"
if (-not $emls) {
  throw "no .msg or .pst content under $Work - check the export downloaded and unpacked"
}

# refuse to run blind if the folder structure was lost upstream
$hasMatter = $false
foreach ($e in ($emls | Select-Object -First 500)) {
  if (Get-MatterHint (Split-Path (Split-Path $e.FullName -Parent) -Leaf)) { $hasMatter = $true; break }
}
if (-not $hasMatter) {
  throw "no file-number folders in the extract. The export was almost certainly run " +
        "without 'Include folder and path of the source', so matter attribution is gone. " +
        "Re-export with that option rather than filing 300,000 messages as Unsorted."
}

# ---------------------------------------------------------------- 3. key + plan
Write-Host "`nscoring against the index (nothing is written yet)"
# scan $Work: it contains the unpacked .msg AND $emlRoot, so one pass covers both routes
foreach ($r in $roots) { & $py (Join-Path $PSScriptRoot 'ingest-key.py') plan $r --index $IndexPath }

# ---------------------------------------------------------------- 4. upload
$sent = 0; $skipped = 0; $nokey = 0; $errors = 0
$newIndexRows = New-Object System.Collections.Generic.List[string]

foreach ($e in $emls) {
  if ($Limit -gt 0 -and $sent -ge $Limit) { break }

  $j = & $py (Join-Path $PSScriptRoot 'ingest-key.py') check $e.FullName
  $token = ($j | Select-String 'token      : (.+)$').Matches.Groups[1].Value.Trim()
  $name  = ($j | Select-String 'blob name  : (.+)$').Matches.Groups[1].Value.Trim()
  $mid   = ($j | Select-String 'message-id : (.+)$').Matches.Groups[1].Value.Trim()
  if (-not $token -or $token -eq 'None') { $nokey++; continue }
  if ($done.ContainsKey($token)) { $skipped++; continue }

  $parent = Split-Path $e.FullName -Parent
  $leaf   = Split-Path $parent -Leaf
  $matter = Get-MatterHint $leaf
  if (-not $matter) { $matter = 'UnsortedMatterCommunication' }

  # Deleted mail must not masquerade as filed correspondence.
  #
  # 16 of the 17 subfolders under the archive's Deleted Items are named as file numbers
  # (02.353, 06.162, 100.072, 109.029 ...), so the matter rule above resolves them to a
  # real matter and would drop deleted mail straight into <matter>/Emails/ - visually
  # identical to correspondence someone chose to file. For a legal archive that is the
  # wrong default: it is not a filing, it is something a person deleted.
  #
  # Same folder, different container. Still ingested, still searchable, still attributed
  # to its matter - but the path says where it came from, and nothing has to be trusted
  # to remember. 1,657 items sit under Deleted Items today.
  # .eml sits under $emlRoot (extracted from a PST); .msg sits under $Work where it was
  # unpacked. Measure the relative path from whichever root actually contains this file.
  $root = if ($parent.StartsWith($emlRoot, [StringComparison]::OrdinalIgnoreCase)) { $emlRoot } else { $Work }
  $rel = $parent.Substring($root.Length).TrimStart('\','/')
  $fromBin = ($rel -split '[\\/]') -contains 'Deleted Items'
  $section = if ($fromBin) { 'DeletedItems' } else { 'Emails' }
  $blob = "$matter/$section/$name"

  if (-not $Execute) {
    if ($sent -lt 10) { Write-Host "  would upload -> $blob" }
    $sent++
    continue
  }

  try {
    & $az storage blob upload --account-name $Account --container-name $Container `
        --name $blob --file $e.FullName --overwrite --auth-mode login --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw "az exit $LASTEXITCODE" }
    Add-Content -Path $checkpoint -Value $token
    $newIndexRows.Add("$blob`t$mid`tok")
    $sent++
    if ($sent % 250 -eq 0) { Write-Host "  uploaded $sent" }
  } catch {
    $errors++
    Write-Warning "upload failed for $blob : $($_.Exception.Message)"
  }
}

# keep the identity map current, so the next run can dedup against this one without a
# 24-minute index rebuild
if ($Execute -and $newIndexRows.Count) {
  Add-Content -Path $IndexPath -Value $newIndexRows
  Write-Host "appended $($newIndexRows.Count) rows to $(Split-Path $IndexPath -Leaf)"
}

Write-Host ""
Write-Host ("=== {0} ===" -f $(if ($Execute) { 'UPLOADED' } else { 'DRY RUN' }))
Write-Host ("  {0,7}  {1}" -f $sent, $(if ($Execute) { 'uploaded' } else { 'would upload' }))
Write-Host ("  {0,7}  already done in an earlier run" -f $skipped)
Write-Host ("  {0,7}  no usable key (missing Message-ID or Date)" -f $nokey)
Write-Host ("  {0,7}  errors" -f $errors)
if (-not $Execute) { Write-Host "`nre-run with -Execute to upload." }

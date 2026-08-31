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
$psts = Get-ChildItem $Work -Filter *.pst -Recurse -ErrorAction SilentlyContinue
Write-Host "PSTs found: $($psts.Count)"
if (-not $psts) { throw "no PSTs under $Work - check the export downloaded and unpacked" }

# ---------------------------------------------------------------- 2. PST -> .eml
foreach ($p in $psts) {
  $marker = Join-Path $emlRoot ("." + [IO.Path]::GetFileNameWithoutExtension($p.Name) + ".extracted")
  if (Test-Path $marker) { Write-Host "already extracted: $($p.Name)"; continue }
  Write-Host "extracting $($p.Name)"
  & (Join-Path $PSScriptRoot 'pst-to-eml.ps1') -Pst $p.FullName -Out $emlRoot
  New-Item -ItemType File -Force -Path $marker | Out-Null
}

$emls = Get-ChildItem $emlRoot -Filter *.eml -Recurse
Write-Host "extracted messages: $($emls.Count)"

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
& $py (Join-Path $PSScriptRoot 'ingest-key.py') plan $emlRoot --index $IndexPath

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

  $leaf   = Split-Path (Split-Path $e.FullName -Parent) -Leaf
  $matter = Get-MatterHint $leaf
  if (-not $matter) { $matter = 'UnsortedMatterCommunication' }
  $blob = "$matter/Emails/$name"

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

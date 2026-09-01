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
  # NOT inside the repo. This holds every extracted message - ~204 GB for the full
  # archive - and unpacked packages besides. Defaults beside the source, which is where
  # the disk space already had to be.
  [string]$Work        = (Join-Path (Split-Path $Source -Parent) 'rse-ingest-work'),
  [string]$Account     = 'samatters',
  [string]$Container   = 'matters',
  [string]$IndexPath   = (Join-Path $PSScriptRoot 'messageid-index.tsv'),
  [int]$Limit          = 0,
  # 12 keeps the uplink busy without provoking storage throttling. Sequential managed
  # 109/min; the network can carry several times that.
  [int]$Parallel       = 12,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$py = 'python'

# Same rule as sweep-older-mail.ps1 / reconcile-missed.ps1, with one addition those two do
# not need: the Purview export sanitises folder names, replacing BOTH dots and spaces with
# hyphens. Matter 32.061 arrives as "32-061", and "Deleted Items" as "Deleted-Items".
#
# The hyphen form is accepted and normalised back to the dot form, because that is what
# the existing 258,974 blobs use. Without this, ingested mail would file into a parallel
# set of "32-061" folders sitting next to the real "32.061" ones - which is worse than
# failing, because it looks like it worked.
function Get-MatterHint([string]$leaf) {
  $t = "$leaf".Trim()
  if ($t -match '^\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?$') { return $t }
  if ($t -match '^(\d{2,3}[A-Z]?)-(\d{3,4}[A-Z]?)$') { return "$($Matches[1]).$($Matches[2])" }
  ''
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$emlRoot    = Join-Path $Work 'eml'
$checkpoint = Join-Path $Work 'done.txt'
$done = @{}
if (Test-Path $checkpoint) { Get-Content $checkpoint | ForEach-Object { $done[$_] = $true } }
Write-Host "checkpoint holds $($done.Count) already-uploaded tokens"

# ---------------------------------------------------------------- 1. unpack
# Only unpack archives that actually contain messages. Pointing -Source at a Downloads
# folder is the normal case, and it will hold unrelated zips - installers, other tools.
# Unpacking those wastes time and disk and buries the real content. Decided by listing
# each archive rather than by its name, since Purview's package names vary and the
# reports package (CSV only, no messages) is easy to mistake for the items package.
# Windows ships bsdtar at System32\tar.exe, but Git Bash puts GNU tar on PATH ahead of it,
# and GNU tar reads "C:\..." as a remote host:path spec - "Cannot connect to C: resolve
# failed", exit 128. Whether the archive check worked therefore depended on PATH order,
# which is not a thing to leave to chance.
$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $tarExe)) { throw "Windows tar not found at $tarExe" }

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zips = Get-ChildItem $Source -Filter *.zip -Recurse -ErrorAction SilentlyContinue
foreach ($z in $zips) {
  $dest = Join-Path $Work ([IO.Path]::GetFileNameWithoutExtension($z.Name))
  if (Test-Path $dest) { continue }

  # Read the central directory rather than streaming the archive: it answers the question
  # in under a second even for a 4.7 GB package, and it cannot be confused by which tar is
  # on PATH. A failure to open is reported rather than silently treated as "no mail",
  # which would skip a real export package.
  $hasMail = $false
  try {
    $zf = [IO.Compression.ZipFile]::OpenRead($z.FullName)
    try {
      foreach ($entry in $zf.Entries) {
        if ($entry.FullName -match '\.(msg|pst)$') { $hasMail = $true; break }
      }
    } finally { $zf.Dispose() }
  } catch {
    Write-Warning "could not read $($z.Name): $($_.Exception.Message) - skipping"
    continue
  }
  if (-not $hasMail) {
    Write-Host "skipping $($z.Name) - no .msg or .pst inside"
    continue
  }

  Write-Host "unpacking $($z.Name)"
  # bsdtar for the extraction: .NET's ExtractToDirectory refuses the long paths Purview
  # produces, while bsdtar writes them via the \\?\ prefix.
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  & $tarExe -xf $z.FullName -C $dest
}
# ---------------------------------------------------------------- 2. get to messages
# Purview exports either .msg files or PSTs. Prefer .msg: it needs no PST cracking, so no
# Outlook, no MAPI and no commercial library, and Azure AI Search indexes it natively.
# PST support stays for packages already exported that way.
# Look in both places. $Work holds anything this script unpacked; $Source holds the
# download itself, which is often already unpacked by hand - that is a normal way to
# arrive here, not a mistake, so it has to work.
# Get-Item, not Resolve-Path: Resolve-Path preserves 8.3 short names (ADMIN-~3) while
# Get-ChildItem returns the long form (admin-MTSG3). Mixing the two silently breaks the
# manifest join - every message keys as "no usable key" while the manifest looks correct.
$Work = (Get-Item $Work).FullName
$roots = @($Work)
$srcFull = (Get-Item $Source).FullName
if ($srcFull -ne $Work) { $roots += $srcFull }
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

# ---------------------------------------------------------------- 3. upload
# Refresh on the token's ACTUAL expiry, not on how long ago we asked for one.
# `az account get-access-token` returns a CACHED token, so a token fetched "just now" can
# already be most of the way through its life. Refreshing every N minutes from the time of
# the call therefore expires mid-run - which is what happened, as a wall of 401s.
$script:blobToken = ''
$script:blobTokenExp = [datetime]::MinValue
function Get-BlobToken {
  $j = (& $az account get-access-token --resource https://storage.azure.com/ -o json) | ConvertFrom-Json
  if (-not $j.accessToken) { throw "could not get a storage token - run 'az login' first" }
  $script:blobToken = $j.accessToken
  $script:blobTokenExp = if ($j.expiresOn) { [datetime]::Parse($j.expiresOn) } else { (Get-Date).AddMinutes(50) }
}
if ($Execute) { Get-BlobToken; Write-Host ("storage token valid until {0:HH:mm}" -f $script:blobTokenExp) }

# One HttpClient for the whole run. It is thread-safe and pools connections, which is the
# entire point - a client per request would reintroduce the handshake cost being removed.
$handler = [Net.Http.SocketsHttpHandler]::new()
$handler.MaxConnectionsPerServer = 64
$httpClient = [Net.Http.HttpClient]::new($handler)
$httpClient.Timeout = [TimeSpan]::FromMinutes(10)
$sent = 0; $skipped = 0; $nokey = 0; $errors = 0
$newIndexRows = New-Object System.Collections.Generic.List[string]

# Key every message in ONE pass. This used to shell out to Python per file, which meant
# an interpreter start per message - tolerable for a handful, ruinous for 425,840, where
# process startup would have dominated the entire run.
$manifest = Join-Path $Work 'manifest.tsv'
foreach ($r in $roots) {
  $part = Join-Path $Work ("manifest-" + [IO.Path]::GetFileName($r) + ".tsv")
  # --resume: a keying pass over a large batch runs for tens of minutes, and re-running
  # after an interruption should not start from nothing.
  & $py (Join-Path $PSScriptRoot 'ingest-key.py') manifest $r $part --resume
  if (Test-Path $part) {
    if (Test-Path $manifest) { Get-Content $part | Select-Object -Skip 1 | Add-Content $manifest }
    else { Copy-Item $part $manifest }
  }
}
$keyed = @{}
foreach ($row in (Import-Csv $manifest -Delimiter "`t")) { $keyed[$row.path] = $row }
Write-Host "keyed in manifest: $($keyed.Count)"

# Score against the index from the manifest, rather than parsing every message a second
# time. This was a separate `ingest-key.py plan` pass, so each run parsed the whole batch
# twice - about 4 minutes wasted on 10,892 messages, and hours across 425,840.
Write-Host "`nscoring against the index (nothing is written yet)"
$idx = @{}
if (Test-Path $IndexPath) {
  $reader = [IO.File]::OpenText($IndexPath)
  try {
    [void]$reader.ReadLine()          # header
    while ($null -ne ($line = $reader.ReadLine())) {
      $c = $line.Split("`t")
      if ($c.Count -ge 3 -and $c[2].Trim() -eq 'ok' -and $c[1].Trim()) {
        $idx[$c[1].Trim().ToLowerInvariant()] = $true
      }
    }
  } finally { $reader.Close() }
}
$already = 0; $fresh = 0; $tokenCount = @{}
foreach ($row in $keyed.Values) {
  if ($row.messageId -and $idx.ContainsKey($row.messageId.ToLowerInvariant())) { $already++ } else { $fresh++ }
  $tokenCount[$row.token] = 1 + $tokenCount[$row.token]
}
$dupes = @($tokenCount.Values | Where-Object { $_ -gt 1 }).Count
Write-Host ("  index holds                       : {0,7:N0} message-ids" -f $idx.Count)
Write-Host ("  message-id already in the archive : {0,7:N0}" -f $already)
Write-Host ("  not seen before                   : {0,7:N0}" -f $fresh)
Write-Host ("  identical keys within this batch  : {0,7:N0}  (same message twice - they overwrite)" -f $dupes)
Write-Host ""

# Work out every blob path first, then upload. Deciding the destination is pure string
# work and costs nothing; keeping it out of the parallel block keeps the matter rules in
# one place and single-threaded, where they are easy to reason about.
$uploads = New-Object System.Collections.Generic.List[object]
foreach ($e in $emls) {
  if ($Limit -gt 0 -and $uploads.Count -ge $Limit) { break }

  $k = $keyed[$e.FullName]
  if (-not $k) { $nokey++; continue }
  $token = $k.token; $name = $k.blobName; $mid = $k.messageId
  if (-not $token) { $nokey++; continue }
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
  # A message can sit under $emlRoot (extracted from a PST), under $Work (a package this
  # run unpacked) or under $Source (a download already unpacked by hand). Pick the longest
  # matching root, so $emlRoot wins over the $Work that contains it. Assuming $Work threw
  # "startIndex cannot be larger than length of string" the moment a file lived elsewhere.
  $root = @($emlRoot) + $roots |
            Where-Object { $_ -and $parent.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object -Property Length -Descending | Select-Object -First 1
  $rel = if ($root) { $parent.Substring($root.Length).TrimStart('\','/') } else { $parent }
  # 'Deleted Items' in the mailbox; 'Deleted-Items' once the export has sanitised it.
  $segs = $rel -split '[\\/]'
  $fromBin = ($segs -contains 'Deleted Items') -or ($segs -contains 'Deleted-Items')
  $section = if ($fromBin) { 'DeletedItems' } else { 'Emails' }
  $blob = "$matter/$section/$name"

  # Encode each path segment separately: %2F would escape the slashes that make the
  # virtual directories the archive is organised by.
  $encoded = ($blob -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
  $uploads.Add([pscustomobject]@{
    File  = $e.FullName
    Blob  = $blob
    Uri   = "https://$Account.blob.core.windows.net/$Container/$encoded"
    Token = $token
    Mid   = $mid
  })
}

if (-not $Execute) {
  foreach ($u in ($uploads | Select-Object -First 10)) { Write-Host "  would upload -> $($u.Blob)" }
  $sent = $uploads.Count
} else {
  # Upload in parallel, in chunks.
  #
  # Sequentially this managed 109 uploads/min - 0.79 MB/s against an uplink measured at
  # 2.6 MB/s. The network was never the limit: each upload was a separate request with its
  # own TLS handshake, and at a 444 KB average that setup cost dominated. The full archive
  # would have taken about 65 hours.
  #
  # Chunking rather than one big parallel pass is deliberate. It gives a natural point to
  # refresh the token and to write the checkpoint and index rows from a single thread,
  # which keeps both files consistent without locking. A crash loses at most one chunk of
  # progress, and re-running skips whatever was already recorded.
  $chunkSize = [Math]::Max($Parallel * 8, 200)
  $total = $uploads.Count
  Write-Host "uploading $total in chunks of $chunkSize, $Parallel at a time"
  $swAll = [Diagnostics.Stopwatch]::StartNew()

  for ($off = 0; $off -lt $total; $off += $chunkSize) {
    if ((Get-Date) -gt $script:blobTokenExp.AddMinutes(-5)) { Get-BlobToken }
    $chunk = $uploads[$off..([Math]::Min($off + $chunkSize, $total) - 1)]
    $tok = $script:blobToken

    $results = $chunk | ForEach-Object -ThrottleLimit $Parallel -Parallel {
      $item = $_
      try {
        # HttpClient rather than Invoke-WebRequest: it pools connections, so the TLS
        # handshake is paid once per thread instead of once per message.
        $client = $using:httpClient
        $fs = [IO.File]::OpenRead($item.File)
        try {
          $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, $item.Uri)
          $req.Content = [Net.Http.StreamContent]::new($fs)
          $req.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
          $req.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $using:tok)
          $req.Headers.Add('x-ms-version', '2021-12-02')
          $req.Headers.Add('x-ms-blob-type', 'BlockBlob')
          $resp = $client.SendAsync($req).GetAwaiter().GetResult()
          [pscustomobject]@{ Ok = $resp.IsSuccessStatusCode; Code = [int]$resp.StatusCode
                             Blob = $item.Blob; Token = $item.Token; Mid = $item.Mid }
        } finally { $fs.Dispose() }
      } catch {
        [pscustomobject]@{ Ok = $false; Code = -1; Blob = $item.Blob
                           Token = $item.Token; Mid = $item.Mid; Err = $_.Exception.Message }
      }
    }

    # single-threaded: safe to append to the checkpoint and the index
    foreach ($r in $results) {
      if ($r.Ok) {
        Add-Content -Path $checkpoint -Value $r.Token
        $newIndexRows.Add("$($r.Blob)`t$($r.Mid)`tok")
        $sent++
      } else {
        $errors++
        Write-Warning "upload failed ($($r.Code)) for $($r.Blob)$(if ($r.Err) { " : $($r.Err)" })"
      }
    }
    $rate = if ($swAll.Elapsed.TotalMinutes -gt 0) { $sent / $swAll.Elapsed.TotalMinutes } else { 0 }
    $left = if ($rate -gt 0) { ($total - $sent) / $rate } else { 0 }
    Write-Host ("  {0,6}/{1}  {2:N0}/min  ~{3:N0} min left" -f $sent, $total, $rate, $left)
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

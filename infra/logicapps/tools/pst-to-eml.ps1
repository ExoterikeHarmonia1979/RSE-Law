#requires -Version 7
<#
Extract a PST to .eml, preserving the folder structure.

The eDiscovery export delivers PSTs. Everything downstream - ingest-key.py, the blob
name, the search index - works on .eml, so this is the step between them.

WHY NOT readpst
---------------
libpst is the obvious tool and is not usable here: there is no official Windows build,
and the Python bindings (pypff, libratom) ship no Windows wheels, so pip tries to compile
and fails on a box with no compiler and no elevation. Redemption is already present for
this project, exposes LogonPstStore, and writes MIME directly via olRFC822. It reads the
PST through Outlook's own MAPI, so fidelity is native rather than reverse-engineered.

Note Redemption is commercial and licensed per developer. It is load-bearing here, not a
discarded experiment, so the licence has to be real before this runs in anger.

FOLDER STRUCTURE IS NOT COSMETIC
--------------------------------
A message's matter is determined by the folder it sits in - that is the rule
sweep-older-mail.ps1 and reconcile-missed.ps1 already use, and the only classification a
person actually made. So the PST folder path is mirrored into the output directory and
must not be flattened. Export the PST from Purview with "Include folder and path of the
source" selected, or this information is gone before we ever see it.

VERIFIED
--------
Six real messages pulled from the blob container, pushed into a PST and pulled back out:
Message-ID and sent date survived on all six, and ingest-key.py derived byte-identical
tokens before and after. Timezone normalisation held too (10:33:58 -0700 -> 17:33:58Z).

The MIME is regenerated rather than copied, so the bytes are not identical to the source
(238,160 in, 234,001 out on one sample). Content is equivalent. This is the same class of
thing the live Logic App already does, which stores Graph-generated MIME, but it is worth
being explicit that this is not a bit-exact copy.

  ./pst-to-eml.ps1 -Pst export.pst -Out .\extracted
  ./pst-to-eml.ps1 -Pst export.pst -Out .\extracted -Limit 200   # smoke test first
#>
param(
  [Parameter(Mandatory)][string]$Pst,
  [Parameter(Mandatory)][string]$Out,
  [int]$Limit = 0,
  # Redemption64.dll, registered under HKCU so no elevation is needed. See
  # INGEST-BLOB-NAMING.md for the registration.
  [string]$RedemptionClsid = '{29ab7a12-b531-450e-8f7a-ea94c2f3c05f}'
)
$ErrorActionPreference = 'Stop'
$olRFC822 = 1024

if (-not (Test-Path $Pst)) { throw "PST not found: $Pst" }
if (-not (Test-Path "HKCU:\Software\Classes\CLSID\$RedemptionClsid")) {
  throw "Redemption is not registered for this user. See INGEST-BLOB-NAMING.md."
}
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }

# Creating RDOSession on the caller's thread hangs - the apartment state the host gives
# us is wrong for it. In a job it returns immediately. This is not a workaround for a
# transient fault; it is reproducible, so the work runs in a job by design.
$work = {
  param($Pst, $Out, $Limit, $olRFC822)

  $s = New-Object -ComObject Redemption.RDOSession
  Write-Output "Redemption $($s.Version)"
  $store = $s.LogonPstStore($Pst, 0, 'IngestExtract')   # 0 = open existing
  Write-Output "opened: $Pst"

  $script:written = 0
  $script:failed  = 0
  $script:folders = 0

  # Windows path components cannot carry these, and a long subject will blow past
  # MAX_PATH once the matter path is prepended.
  function Safe-Name([string]$n) {
    $x = ($n -replace '[\\/:*?"<>|\r\n\t]', '_').Trim()
    if ($x.Length -gt 60) { $x = $x.Substring(0, 60).Trim() }
    if (-not $x) { $x = '_' }
    $x
  }

  function Walk($folder, $relPath) {
    if ($Limit -gt 0 -and $script:written -ge $Limit) { return }
    $script:folders++
    $dir = if ($relPath) { Join-Path $Out $relPath } else { $Out }
    $n = 0
    foreach ($item in $folder.Items) {
      if ($Limit -gt 0 -and $script:written -ge $Limit) { break }
      $n++
      try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Name by ordinal, not subject: the authoritative name is derived later by
        # ingest-key.py from the message's own headers. Naming twice invites drift.
        $dest = Join-Path $dir ("{0:D6}.eml" -f $n)
        $item.SaveAs($dest, $olRFC822)
        $script:written++
      } catch {
        $script:failed++
        Write-Output "  FAILED $relPath item $n : $($_.Exception.Message)"
      }
    }
    foreach ($sub in $folder.Folders) {
      Walk $sub (if ($relPath) { Join-Path $relPath (Safe-Name $sub.Name) } else { Safe-Name $sub.Name })
    }
  }

  Walk $store.IPMRootFolder ''

  Write-Output ""
  Write-Output "folders walked : $($script:folders)"
  Write-Output "written        : $($script:written)"
  Write-Output "failed         : $($script:failed)"
  $s = $null
  [GC]::Collect()
}

$job = Start-Job -ScriptBlock $work -ArgumentList $Pst, $Out, $Limit, $olRFC822
if (Wait-Job $job -Timeout 7200) { Receive-Job $job }
else { Stop-Job $job; throw "extraction exceeded 2 hours - split the PST and retry" }
Remove-Job $job -Force

Write-Host ""
Write-Host "Next: score the output before uploading anything -"
Write-Host "  python ingest-key.py plan `"$Out`" --index messageid-index.tsv"

#requires -Version 7
<#
How many old-format blobs are superseded, and how many are not?

Old naming was "<subject>.eml"; new is "<subject> [<id tail>].eml". An old blob is superseded
when a new-format blob exists in the SAME matter with the same subject stem - that is the same
message, rewritten per-message. Those are the safe deletions.

Two things stop this being a simple subtraction:

  - the subject cap changed from 180 to 150 characters, so stems are compared on the first
    150 characters or long subjects would look like non-matches
  - the sanitiser changed between eras ("Re:" vs "Re_"), so some old blobs will never match
    anything. Those are NOT safe to delete - they may be the only copy of a message that no
    longer resolves the same way - and are counted separately as orphans

Attachments are excluded entirely: their naming never gained a suffix, so every attachment
blob looks "old" and none of this applies to them.

Read-only. Deletes nothing.
#>
param([switch]$Refresh)
$ErrorActionPreference = 'Stop'
$sp   = $PSScriptRoot
$az   = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$dump = Join-Path $sp 'allblobs2.txt'

if ($Refresh -or -not (Test-Path $dump)) {
  Write-Host "listing the container (this takes a while) ..."
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $az storage blob list --account-name samatters --container-name matters `
      --num-results "*" --auth-mode login --query "[].name" -o tsv 2>$null | Set-Content $dump
  $sw.Stop()
  Write-Host ("listed in {0} min" -f [math]::Round($sw.Elapsed.TotalMinutes,1))
}

$names = Get-Content $dump
Write-Host "blobs: $($names.Count)"

# top-level matter emails only
$eml = @($names | Where-Object { $_ -like '*/Emails/*.eml' -and $_ -notlike '*/Emails/Attachments/*' })
Write-Host "matter emails: $($eml.Count)"

$byMatter = @{}
foreach ($p in $eml) {
  $parts = $p -split '/'
  $matter = $parts[0]
  $file   = $parts[-1] -replace '\.eml$',''
  $m = [regex]::Match($file, '^(.*?)\s\[([^\]]+)\]$')
  if (-not $byMatter.ContainsKey($matter)) { $byMatter[$matter] = @{ New=@{}; Old=@() } }
  if ($m.Success) {
    $stem = $m.Groups[1].Value.Trim()
    if ($stem.Length -gt 150) { $stem = $stem.Substring(0,150).Trim() }
    $byMatter[$matter].New[$stem] = $true
  } else {
    $byMatter[$matter].Old += ,@($file, $p)
  }
}

$oldTotal = 0; $superseded = 0; $orphan = 0; $orphanSamples = @(); $supersededPaths = @()
foreach ($matter in $byMatter.Keys) {
  foreach ($o in $byMatter[$matter].Old) {
    $oldTotal++
    $stem = $o[0].Trim()
    if ($stem.Length -gt 150) { $stem = $stem.Substring(0,150).Trim() }
    if ($byMatter[$matter].New.ContainsKey($stem)) {
      $superseded++; $supersededPaths += $o[1]
    } else {
      $orphan++
      if ($orphanSamples.Count -lt 8) { $orphanSamples += $o[1] }
    }
  }
}
$supersededPaths | Set-Content (Join-Path $sp 'superseded.txt')

Write-Host ""
Write-Host "old-format matter emails      : $oldTotal"
Write-Host "  superseded by a new copy    : $superseded   <- safe to delete"
Write-Host "  no new-format counterpart   : $orphan   <- NOT safe; may be the only copy"
Write-Host ""
Write-Host "unsorted bucket:"
$uOld = @($eml | Where-Object { $_ -like 'UnsortedMatterCommunication/*' -and $_ -notmatch '\s\[[^\]]+\]\.eml$' })
$uNew = @($eml | Where-Object { $_ -like 'UnsortedMatterCommunication/*' -and $_ -match '\s\[[^\]]+\]\.eml$' })
Write-Host "  old-format=$($uOld.Count)  new-format=$($uNew.Count)"
Write-Host ""
Write-Host "sample orphans (would be kept):"
$orphanSamples | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "superseded list written to superseded.txt ($superseded paths)"

#requires -Version 7
<#
Re-file emails sitting in UnsortedMatterCommunication under the matter their subject
actually names.

These are already archived .eml blobs, so this is a server-side blob move, not a mail
replay - there is no Service Bus event to re-raise for them. The blob name is the
sanitised subject, which is what the matcher reads.

Copy is server-side (x-ms-copy-source), so content never travels through this machine.
The source is deleted only after the destination is confirmed present, so an interrupted
run leaves duplicates rather than losing anything.

Attachments under UnsortedMatterCommunication/Emails/Attachments/ are deliberately left
alone: they are keyed by attachment filename with no reference back to their message, so
they cannot be mapped to a matter. The .eml is full MIME and already contains them.
#>
param(
  [int]$Max = 5000,
  [switch]$Execute,          # dry run unless set
  [string]$Account = 'samatters',
  [string]$Container = 'matters',
  [string]$SourcePrefix = 'UnsortedMatterCommunication/Emails/'
)
$ErrorActionPreference = 'Stop'
# Known limitation: az warns "Unable to encode the output with cp1252 encoding.
# Unsupported characters are discarded" and mangles blob names containing emoji,
# curly quotes or CJK - 5 of 2380 when last measured. The loss happens inside az
# before the output reaches PowerShell, so neither [Console]::OutputEncoding nor
# PYTHONIOENCODING helps; only listing over the REST API would. Those blobs fail
# safe: the copy 404s and is counted as failed, with the source left in place.
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$key = (Get-Content "$env:TEMP\sakey.txt" -Raw).Trim()
$fn  = 'https://regexazfunc.azurewebsites.net/api/RegExMattersAzFunc'
$root = "https://$Account.blob.core.windows.net/$Container"

$expiry = (Get-Date).ToUniversalTime().AddHours(4).ToString('yyyy-MM-ddTHH:mm:ssZ')
$sas = (& $az storage container generate-sas --account-name $Account --account-key $key `
          --name $Container --permissions racwd --expiry $expiry -o tsv).Trim()
if (-not $sas) { throw 'could not mint a container SAS' }

# '*' means every page. A literal cap silently truncates the listing, so blobs past
# the cap would never be seen however often this is re-run - and the sweep keeps
# adding to this prefix, so the bucket does cross 5000.
$blobs = & $az storage blob list --account-name $Account --account-key $key -c $Container `
            --prefix $SourcePrefix --num-results '*' -o json | ConvertFrom-Json
# top-level .eml only - never the Attachments/ subfolder
$emls = @($blobs | Where-Object {
  $_.name -like '*.eml' -and ($_.name -replace [regex]::Escape($SourcePrefix), '') -notlike '*/*'
})
Write-Host "unsorted .eml blobs: $($emls.Count)"

$moved = 0; $skipped = 0; $failed = 0
foreach ($b in ($emls | Select-Object -First $Max)) {
  $leaf = $b.name -replace [regex]::Escape($SourcePrefix), ''
  $subject = $leaf -replace '\.eml$', ''

  try {
    $r = Invoke-RestMethod -Method Post -Uri $fn -TimeoutSec 30 -ContentType 'application/json' `
           -Body (@{ strData = $subject } | ConvertTo-Json -Compress)
  } catch { $failed++; continue }

  # Only a strict RSE File No is trusted. A Case/Claim number needs the lookup list to map
  # it onto a matter, and this script has no access to that mapping.
  if ("$($r.type)" -ne 'RSE File No' -or -not "$($r.match)") { $skipped++; continue }
  $matter = "$($r.match)"

  $srcPath = ($b.name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
  $dstLeaf = [uri]::EscapeDataString($leaf)
  $dstPath = "$([uri]::EscapeDataString($matter))/Emails/$dstLeaf"

  if (-not $Execute) { Write-Host "would move -> $matter/Emails/$leaf"; $moved++; continue }

  try {
    Invoke-WebRequest -Method Put -Uri "$root/$dstPath`?$sas" -Headers @{
      'x-ms-copy-source' = "$root/$srcPath`?$sas"
      'x-ms-version'     = '2021-08-06'
    } -ErrorAction Stop | Out-Null

    # confirm the destination exists before removing the only other copy
    $head = Invoke-WebRequest -Method Head -Uri "$root/$dstPath`?$sas" -ErrorAction Stop
    if ($head.StatusCode -ne 200) { throw "destination missing after copy" }

    Invoke-WebRequest -Method Delete -Uri "$root/$srcPath`?$sas" -ErrorAction Stop | Out-Null
    $moved++
  } catch {
    Write-Warning "$leaf -> $matter : $($_.Exception.Message)"
    $failed++
    if ($failed -gt 15) { Write-Warning 'too many failures, stopping'; break }
  }
}
Write-Host ("{0}: moved={1} skipped={2} failed={3}" -f $(if($Execute){'EXECUTED'}else{'DRY RUN'}), $moved, $skipped, $failed)

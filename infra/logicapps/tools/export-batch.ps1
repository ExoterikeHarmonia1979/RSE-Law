#requires -Version 7
<#
Run one Content Search batch against the matters@ In-Place Archive, ready to export.

The archive is ~425,840 items / ~204 GB, and Purview caps a zip package at 40 GB, expires
export packages after 14 days, and cancels any export still running after 7 days. So the
corpus has to come across in batches; this runs one.

The export download itself is a browser step and is not scriptable: Connect-IPPSSession
needs an interactive window handle, and the eDiscovery Export Tool was retired in favour
of in-browser download. The portal settings that matter are printed at the end.

MUST run in PowerShell 7. The 5.1 and ISE builds authenticate through the WAM broker and
fail with "A window handle must be configured".

  ./export-batch.ps1 -From 2024-06-01 -To 2024-06-30
  ./export-batch.ps1 -From 2024-01-01 -To 2024-03-31 -Name RSE-Archive-2024Q1
#>
param(
  [Parameter(Mandatory)][string]$From,
  [Parameter(Mandatory)][string]$To,
  [string]$Name,
  [string]$Mailbox = 'matters@rse-law.com',
  [string]$RunAs   = 'SharePoint@rse-law.com'
)
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core') {
  throw "Run this in pwsh (PowerShell 7). Current edition: $($PSVersionTable.PSEdition)"
}
if (-not $Name) { $Name = "RSE-Archive-$($From -replace '-','')-$($To -replace '-','')" }

Import-Module ExchangeOnlineManagement

# -EnableSearchOnlySession is mandatory from module v3.9.0. Without it
# Start-ComplianceSearch fails at initialisation and the search STILL reports
# Status=Completed with Items=0 - indistinguishable from an empty archive unless you read
# Errors. Never trust a zero here without checking it.
if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
  Connect-IPPSSession -UserPrincipalName $RunAs -EnableSearchOnlySession
}
$who = (Get-ConnectionInformation | Select-Object -First 1).UserPrincipalName
Write-Host "connected as $who"

Write-Host ""
Write-Host "=== $Name : $From .. $To on $Mailbox ==="
if (Get-ComplianceSearch -Identity $Name -ErrorAction SilentlyContinue) {
  Remove-ComplianceSearch -Identity $Name -Confirm:$false
}
New-ComplianceSearch -Name $Name `
  -ExchangeLocation $Mailbox `
  -ContentMatchQuery "sent>=$From AND sent<=$To" | Out-Null
Start-ComplianceSearch -Identity $Name

do {
  Start-Sleep -Seconds 10
  $s = Get-ComplianceSearch -Identity $Name
  Write-Host ("  status={0}  items={1}  size={2:N0}" -f $s.Status, $s.Items, $s.Size)
} while ($s.Status -notin 'Completed','Failed')

Write-Host ""
if ($s.Errors) {
  Write-Warning "search reported errors: $($s.Errors)"
  Write-Warning "do not read Items=0 as an empty archive until these are resolved."
  return
}
if ($s.Items -eq 0) {
  Write-Warning "zero items with no errors - widen the window, or check the archive is indexed."
  return
}

$gb = $s.Size / 1GB
Write-Host ("  {0:N0} items, {1:N1} GB" -f $s.Items, $gb)
if ($gb -gt 35) {
  Write-Warning ("{0:N1} GB is close to the 40 GB package cap - narrow the window." -f $gb)
}

Write-Host ""
Write-Host "=== export from the portal: https://purview.microsoft.com ==="
Write-Host "  eDiscovery -> Cases -> Searches -> $Name -> Export"
Write-Host ""
Write-Host "  Export format          : Create .msg files for messages    <- NOT PST"
Write-Host "  Output package options : [x] Include folder and path of the source"
Write-Host "                           [x] Give each item a friendly name"
Write-Host ""
Write-Host "  'Include folder and path of the source' carries the MATTER. Without it every"
Write-Host "  message arrives flat, files as UnsortedMatterCommunication, and ingest-run.ps1"
Write-Host "  refuses rather than misfiling the batch."
Write-Host ""
Write-Host "Then Process manager -> Export -> Download ALL packages (the Items ones are the"
Write-Host "mail; the Reports one is only CSVs), and run:"
Write-Host ""
Write-Host "  .\ingest-packages.ps1 -Source C:\Users\admin-MTSG3\export"
Write-Host ""
Write-Host "  Use ingest-packages.ps1, NOT ingest-run.ps1. ingest-run.ps1 wants the whole"
Write-Host "  quarter extracted at once - 2026 Q1 was six packages and 53 GB, which filled"
Write-Host "  the disk. ingest-packages.ps1 does one package at a time and reclaims the"
Write-Host "  space before the next, so quarter size stops mattering. It calls"
Write-Host "  ingest-run.ps1 per package underneath, and is safe to interrupt and re-run."

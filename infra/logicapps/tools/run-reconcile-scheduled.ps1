#requires -Version 7
<#
Scheduled-task wrapper for reconcile-missed.ps1.

Graph drops change notifications - roughly 137 "Missed" events a day across the subscribed
mailboxes - and the archive workflow discards those silently. This runs the reconciler on a
trailing window so that mail is picked up without anyone noticing the gap first.

Deliberately does NOT scan run history for Missed events: that costs one API call per run in
the history and only tells us where to start the window. Reconciling a fixed trailing window
covers Missed events whether or not we counted them, and covers throttling and transient
Graph failures too.

Window is 3 hours against a 2-hourly schedule, so consecutive runs overlap by an hour and a
message arriving at a boundary cannot fall between them.

Writes one log per run and prunes logs older than 30 days. Exits non-zero on failure so the
task's Last Run Result shows it.

Install (as the account that holds the az login - the script needs Key Vault, Service Bus
and the storage account):

  $act = New-ScheduledTaskAction -Execute "$env:ProgramFiles\PowerShell\7\pwsh.exe" `
           -Argument '-NoProfile -File "C:\Development\REPO\RSE-Law\infra\logicapps\tools\run-reconcile-scheduled.ps1"'
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
           -RepetitionInterval (New-TimeSpan -Hours 2)
  Register-ScheduledTask -TaskName 'RSE-Archive-Reconcile' -Action $act -Trigger $trg `
           -Description 'Recover mail behind Graph Missed notifications' -RunLevel Limited
#>
param(
  [double]$FloorHours = 3,
  [int]$IndexMaxAgeHours = 6,
  [int]$KeepLogDays = 30
)
$ErrorActionPreference = 'Stop'

$sp     = $PSScriptRoot
$logDir = Join-Path $sp 'reconcile-logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("reconcile-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$code = 0
try {
  "=== started $(Get-Date -Format u) ===" | Tee-Object -FilePath $log
  & (Join-Path $sp 'reconcile-missed.ps1') `
      -LookbackHours 0 -FloorHours $FloorHours -IndexMaxAgeHours $IndexMaxAgeHours -Execute `
      *>&1 | Tee-Object -FilePath $log -Append
  if ($LASTEXITCODE) { $code = $LASTEXITCODE }
  "=== finished $(Get-Date -Format u) exit=$code ===" | Tee-Object -FilePath $log -Append
}
catch {
  $code = 1
  "=== FAILED $(Get-Date -Format u) ===" | Tee-Object -FilePath $log -Append
  $_ | Out-String | Tee-Object -FilePath $log -Append
}

Get-ChildItem $logDir -Filter 'reconcile-*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLogDays) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

exit $code

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

HOW THIS FAILED SILENTLY FOR 16 HOURS, AND WHAT STOPS IT REPEATING
------------------------------------------------------------------
Register-ScheduledTask defaults ExecutionTimeLimit to PT1H. The archive index rebuild used
`az storage blob list --num-results "*"`, which on this container takes over an hour, so
every run that had to rebuild the index was KILLED by Task Scheduler mid-listing. A kill is
not an exception: the catch below never ran, nothing wrote "=== FAILED ===", and each log
just stopped after "building the archive index". The task's own Last Run Result said 267014
(SCHED_S_TASK_TERMINATED) and nobody was reading it.

It began the first time the cached index aged past -IndexMaxAgeHours; before that every run
reused the cache and finished in seconds, so the change that broke it was invisible for
hours after it landed.

Three things now have to hold for that to recur:
  - the listing is a paged REST call (~100k blobs/min, minutes not hours) - archive-identity.ps1
  - a failed page throws instead of being swallowed by 2>$null, so the catch fires and logs
  - the run prints blob counts as it goes, so a slow listing looks slow rather than hung

If the container grows enough to approach an hour again, raise the task's limit rather than
letting it be killed:
  Set-ScheduledTask -TaskName 'RSE-Archive-Reconcile' -Settings (New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew)

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

# Get-Date -Format u prints LOCAL time with a literal 'Z' on the end. On a UTC-7 box that
# made the header read 4 hours before the UTC window the script logs a line later, which
# reads exactly like a bug in the window arithmetic and is not one. Print real UTC.
function Now { (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ') }

$code = 0
try {
  "=== started $(Now) ===" | Tee-Object -FilePath $log
  & (Join-Path $sp 'reconcile-missed.ps1') `
      -LookbackHours 0 -FloorHours $FloorHours -IndexMaxAgeHours $IndexMaxAgeHours -Execute `
      *>&1 | Tee-Object -FilePath $log -Append
  if ($LASTEXITCODE) { $code = $LASTEXITCODE }
  "=== finished $(Now) exit=$code ===" | Tee-Object -FilePath $log -Append
}
catch {
  $code = 1
  "=== FAILED $(Now) ===" | Tee-Object -FilePath $log -Append
  $_ | Out-String | Tee-Object -FilePath $log -Append
}

Get-ChildItem $logDir -Filter 'reconcile-*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLogDays) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

exit $code

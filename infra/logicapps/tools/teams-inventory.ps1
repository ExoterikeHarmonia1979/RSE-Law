#requires -Version 7
<#
Full inventory of the .eml files held in the 676 matter Teams.

This is the input to deciding whether those Teams are redundant. It records, per file, the
matter the Team is named for - which is a far more reliable matter attribution than parsing
a subject line, and is the same signal the folder hint uses.

Enumerates every file under each Team's "Email" folder, recursively, so a nested layout is
not missed. Records item ids rather than download URLs: those expire, and this list is meant
to outlive the run that produced it.

Read-only. Writes teams-inventory.json.
#>
param([int]$Parallel = 12)
$ErrorActionPreference = 'Stop'
$sp  = $PSScriptRoot
$az  = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tok = (& $az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
$H   = @{ Authorization = "Bearer $tok" }

$groups=@(); $u="https://graph.microsoft.com/v1.0/groups?`$select=id,displayName&`$top=999"
while($u){ $p=Invoke-RestMethod -Headers $H -Uri $u; $groups+=$p.value; $u=$p.'@odata.nextLink' }
$matter = @($groups | Where-Object { "$($_.displayName)" -match '^\s*\d{2,3}[A-Z]?\.\d{3,4}[A-Z]?\s*$' })
Write-Host "matter Teams: $($matter.Count)"

$bag  = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$errs = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
$done = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()

$matter | ForEach-Object -ThrottleLimit $Parallel -Parallel {
  $g = $_; $h = @{ Authorization = "Bearer $using:tok" }
  $bag = $using:bag; $errs = $using:errs; $done = $using:done
  $mn = "$($g.displayName)".Trim()
  try {
    # walk iteratively - a recursive function is awkward inside a parallel block
    $stack = New-Object System.Collections.Stack
    $root = Invoke-RestMethod -Headers $h -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/drive/root/children?`$select=id,name,folder,size"
    foreach($it in $root.value){ $stack.Push($it) }
    while($stack.Count -gt 0){
      $it = $stack.Pop()
      if($it.folder){
        $u2 = "https://graph.microsoft.com/v1.0/groups/$($g.id)/drive/items/$($it.id)/children?`$select=id,name,folder,size&`$top=200"
        while($u2){
          $p2 = Invoke-RestMethod -Headers $h -Uri $u2
          foreach($c in $p2.value){ $stack.Push($c) }
          $u2 = $p2.'@odata.nextLink'
        }
      } else {
        $bag.Add([pscustomobject]@{
          Matter = $mn; GroupId = $g.id; ItemId = $it.id; Name = $it.name; Size = [int64]$it.size
        })
      }
    }
  } catch { $errs.Add("$mn : $($_.Exception.Message)") }
  [void]$done.AddOrUpdate('n',1,{param($k,$v) $v+1})
  if(($done['n'] % 50) -eq 0){ Write-Host "  ...$($done['n']) Teams walked" }
}

$files = @($bag)
$files | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $sp 'teams-inventory.json') -Encoding utf8

Write-Host ""
Write-Host "Teams walked : $($done['n']) of $($matter.Count)   errors: $($errs.Count)"
Write-Host "files        : $($files.Count)"
Write-Host "total bytes  : $([math]::Round((($files | Measure-Object Size -Sum).Sum)/1GB,2)) GB"
Write-Host ""
Write-Host "by extension:"
$files | Group-Object { $e=[IO.Path]::GetExtension($_.Name).ToLower(); if($e){$e}else{'(none)'} } |
  Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object { "  {0,7}  {1}" -f $_.Count, $_.Name }
Write-Host ""
Write-Host "Teams with no files at all: $(($matter.Count) - (($files | Select-Object -ExpandProperty Matter -Unique).Count))"
Write-Host "files per Team: min/median/max ="
$per = $files | Group-Object Matter | ForEach-Object { $_.Count } | Sort-Object
if($per){ "  {0} / {1} / {2}" -f $per[0], $per[[int]($per.Count/2)], $per[-1] }
if($errs.Count){ Write-Host ""; Write-Host "errors (first 5):"; $errs | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" } }

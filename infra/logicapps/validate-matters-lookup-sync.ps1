#requires -Version 7
<#
Checks for Matters-Lookup-Sync. Separate from validate.ps1 because that one asserts the
archive workflow's invariants (peek-lock trigger, Complete/Abandon, the list of actions
that had to be deleted) - none of which apply here.

The generic checks are the same, and for the same reason: they catch the mistakes the
designer accepts happily and only production reveals. The workflow-specific ones all
guard the same failure - writing garbage into the list the archive resolves matters
against. A duplicated or blanked lookup row misfiles mail silently.
#>
param([string]$Path = "$PSScriptRoot\Matters-Lookup-Sync.json")
$ErrorActionPreference = 'Stop'
$raw = Get-Content $Path -Raw
$res = $raw | ConvertFrom-Json
$def = $res.properties.definition
$fail = 0
function Bad($m){ $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Ok($m){ Write-Host "  ok    $m" -ForegroundColor Green }

# ---- collect every action, and verify runAfter only ever names a sibling
$all = @{}
$scopeOf = @{}
function Walk($actions, $scopeName){
  $sib = @($actions.PSObject.Properties.Name)
  foreach($pr in $actions.PSObject.Properties){
    $n = $pr.Name; $a = $pr.Value
    if($all.ContainsKey($n)){ Bad "duplicate action name '$n'" }
    $all[$n] = $a; $scopeOf[$n] = $scopeName
    foreach($ra in @($a.runAfter.PSObject.Properties.Name)){
      if($ra -and $ra -notin $sib){ Bad "runAfter '$ra' on '$n' is not a sibling in $scopeName" }
    }
    if($a.actions){ Walk $a.actions "$scopeName/$n" }
    if($a.else.actions){ Walk $a.else.actions "$scopeName/$n/else" }
  }
}
Write-Host "`n[1] runAfter graph"
Walk $def.actions 'root'
Ok "$($all.Count) actions walked"

Write-Host "`n[2] orphaned expression references"
$refd = [regex]::Matches($raw, "(?:outputs|body|actions)\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach($r in $refd){ if(-not $all.ContainsKey($r)){ Bad "expression references missing action '$r'" } }
if($script:fail -eq 0){ Ok "all $($refd.Count) referenced actions exist" }

Write-Host "`n[2a] items() targets"
foreach($m in ([regex]::Matches($raw, "items\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)){
  if(-not $all.ContainsKey($m)){ Bad "items('$m') targets missing action" }
  elseif($all[$m].type -ne 'Foreach'){ Bad "items('$m') targets a $($all[$m].type), not Foreach" }
  else { Ok "items('$m') -> Foreach" }
}

# filter()/select() are ACTIONS in Logic Apps (Query/Select). The designer accepts them
# as expressions and they fail at runtime.
Write-Host "`n[2b] invalid expression functions"
$notFunctions = @('filter','select','join_array','map','where','orderby')
function ScanExpr($o, $path){
  if($o -is [string]){
    if($o.StartsWith('@') -or $o -match '@\{'){
      foreach($f in $notFunctions){
        if($o -match "(?<![A-Za-z_])$f\s*\("){ Bad "$path uses '$f(' as an expression; it is an action, not a function" }
      }
    }
  } elseif($o -is [System.Management.Automation.PSCustomObject]){
    foreach($pr in $o.PSObject.Properties){ ScanExpr $pr.Value "$path.$($pr.Name)" }
  } elseif($o -is [System.Collections.IEnumerable]){
    $i = 0; foreach($x in $o){ ScanExpr $x "$path[$i]"; $i++ }
  }
}
ScanExpr $def 'definition'
if($script:fail -eq 0){ Ok "no action-only functions used as expressions" }

Write-Host "`n[2c] Query/Select shapes"
foreach($kv in $all.GetEnumerator()){
  if($kv.Value.type -eq 'Query'){
    if(-not $kv.Value.inputs.from -or -not $kv.Value.inputs.where){ Bad "Query '$($kv.Key)' needs from+where" } else { Ok "Query $($kv.Key)" }
  }
  if($kv.Value.type -eq 'Select'){
    if(-not $kv.Value.inputs.from -or -not $kv.Value.inputs.select){ Bad "Select '$($kv.Key)' needs from+select" } else { Ok "Select $($kv.Key)" }
  }
}

Write-Host "`n[3] trigger"
$tn = @($def.triggers.PSObject.Properties.Name)
if($tn.Count -ne 1){ Bad "expected exactly one trigger, found $($tn.Count)" }
elseif($def.triggers.($tn[0]).type -ne 'Recurrence'){ Bad "trigger '$($tn[0])' is $($def.triggers.($tn[0]).type), not Recurrence" }
else { Ok "$($tn[0]) every $($def.triggers.($tn[0]).recurrence.interval) $($def.triggers.($tn[0]).recurrence.frequency)" }
if($res.properties.state -ne 'Enabled'){ Bad "state is '$($res.properties.state)'; a PUT is a full replace, so deploying this disables the workflow" } else { Ok "state Enabled" }

# The guard is the whole safety story. A zero-item read of the lookup list makes every
# sheet row look missing, and the create loop would then duplicate the entire list.
Write-Host "`n[4] the zero-items guard"
if(-not $all.ContainsKey('Check_inputs')){ Bad "Check_inputs is missing" }
else {
  $expr = $all['Check_inputs'].expression | ConvertTo-Json -Depth 10 -Compress
  foreach($needle in @('Filter_file_column','Filter_claim_column','Get_existing_list_items')){
    if($expr -notmatch [regex]::Escape($needle)){ Bad "Check_inputs does not test $needle" } else { Ok "Check_inputs tests $needle" }
  }
  $t = $all.Keys | Where-Object { $all[$_].type -eq 'Terminate' }
  if(-not $t){ Bad "no Terminate on the guard's else branch" }
  foreach($k in $t){
    if($scopeOf[$k] -notlike '*/Check_inputs/else'){ Bad "Terminate '$k' is not on the guard's else branch" }
    elseif($all[$k].inputs.runStatus -ne 'Failed'){ Bad "Terminate '$k' runStatus is '$($all[$k].inputs.runStatus)', not Failed" }
    else { Ok "Terminate $k fails the run on the else branch" }
  }
}

# Every write must sit inside the guard, or the guard is decorative.
Write-Host "`n[5] writes"
$writes = $all.Keys | Where-Object { $all[$_].type -eq 'ApiConnection' -and $all[$_].inputs.method -in @('post','patch','put','delete') }
if(-not $writes){ Bad "no write actions found at all" }
foreach($w in $writes){
  if($scopeOf[$w] -notlike 'root/Check_inputs/*'){ Bad "write '$w' is outside the Check_inputs guard" }
  else { Ok "write $w is inside the guard ($($all[$w].inputs.method.ToUpper()))" }
}
if($all.Keys | Where-Object { $all[$_].type -eq 'ApiConnection' -and $all[$_].inputs.method -eq 'delete' }){
  Bad "a delete against the lookup list is present; the archive resolves matters against these rows"
}

# strFoundMatter's lesson, one list along: a blank key writes a row that matches nothing
# and hides that it did.
Write-Host "`n[6] no blank keys written"
foreach($w in $writes){
  $b = $all[$w].inputs.body
  if(-not $b){ Bad "write '$w' has no body" ; continue }
  foreach($f in @('Title','RSEFileNo')){
    if(-not $b.PSObject.Properties.Name.Contains($f)){ Bad "write '$w' does not set $f" }
    elseif([string]::IsNullOrWhiteSpace("$($b.$f)")){ Bad "write '$w' sets $f to an empty value" }
  }
}
if($script:fail -eq 0){ Ok "every write sets Title and RSEFileNo" }
# CaseNo is maintained by hand and is not in the spreadsheet - writing it would blank it.
foreach($w in $writes){
  if($all[$w].inputs.body.PSObject.Properties.Name -contains 'CaseNo'){ Bad "write '$w' sets CaseNo, which the spreadsheet does not carry" }
}
Ok "no write touches CaseNo"

# The spreadsheet is NOT authoritative over a claim number somebody already typed in.
# 171 rows disagree today, and in 117 of them the list's ClaimNo holds the court case
# number while CaseNo holds the insurer claim - i.e. the two columns are reversed
# relative to the sheet. Overwriting would delete a token the archive matches subjects
# against, degrading the very lookup this workflow exists to improve. Fill blanks only.
Write-Host "`n[6b] updates only ever fill a blank claim"
if(-not $all.ContainsKey('Filter_to_update')){ Bad "Filter_to_update is missing" }
else {
  $w = "$($all['Filter_to_update'].inputs.where)"
  if($w -notmatch 'Select_existing_blank_claim_files'){
    Bad "Filter_to_update is not scoped to rows whose ClaimNo is blank; it would overwrite curated values"
  } else { Ok "Filter_to_update targets only blank-claim rows" }
}
if(-not $all.ContainsKey('Filter_existing_blank_claim')){ Bad "Filter_existing_blank_claim is missing" }
else {
  $w = "$($all['Filter_existing_blank_claim'].inputs.where)"
  if($w -notmatch "ClaimNo" -or $w -notmatch "''"){ Bad "Filter_existing_blank_claim does not test ClaimNo for blank" }
  else { Ok "Filter_existing_blank_claim tests ClaimNo for blank" }
}
if(-not $all.ContainsKey('Filter_claim_conflicts')){ Bad "Filter_claim_conflicts is missing; conflicts must be counted, not silently dropped" }
else { Ok "conflicts are counted in the run summary" }

Write-Host "`n[7] write cap"
$batches = $all.Keys | Where-Object { $_ -like 'Compose_*_batch' }
if($batches.Count -lt 2){ Bad "expected a capped batch for creates and updates" }
foreach($b in $batches){
  if("$($all[$b].inputs)" -notmatch "take\(" -or "$($all[$b].inputs)" -notmatch "maxWritesPerRun"){
    Bad "$b is not capped with take(..., parameters('maxWritesPerRun'))"
  } else { Ok "$b capped by maxWritesPerRun" }
}
foreach($f in ($all.Keys | Where-Object { $all[$_].type -eq 'Foreach' })){
  $src = "$($all[$f].foreach)"
  if($src -notmatch 'Compose_\w+_batch'){ Bad "Foreach '$f' iterates '$src', not a capped batch" }
  else { Ok "Foreach $f iterates a capped batch" }
}

# Logic App variables are not concurrency-safe; this design has none, and should keep none.
Write-Host "`n[8] no variables"
$vars = $all.Keys | Where-Object { $all[$_].type -match '^(InitializeVariable|SetVariable|AppendTo\w+Variable|IncrementVariable)$' }
if($vars){ Bad "variables present ($($vars -join ', ')); parallel loops drop appends silently" } else { Ok "no variables used" }

Write-Host "`n[9] Graph auth"
foreach($h in ($all.Keys | Where-Object { $all[$_].type -eq 'Http' })){
  $a = $all[$h].inputs.authentication
  if($a.type -ne 'ManagedServiceIdentity'){ Bad "$h auth is '$($a.type)', not ManagedServiceIdentity" } else { Ok "$h uses the managed identity" }
  if($a.audience -ne 'https://graph.microsoft.com'){ Bad "$h audience is '$($a.audience)'" }
  if($all[$h].inputs.headers.Authorization){ Bad "$h sets an Authorization header as well as MSI auth" }
  if(-not $all[$h].inputs.retryPolicy){ Bad "$h has no retryPolicy; the workbook API returns transient WAC token errors" }
  else { Ok "$h retries $($all[$h].inputs.retryPolicy.count)x $($all[$h].inputs.retryPolicy.type)" }
}
if($raw -match 'client_secret=[A-Za-z0-9~._-]{8,}'){ Bad "literal client secret present" } else { Ok "no literal client secret" }

Write-Host "`n[10] `$connections"
$census = @{}
foreach($kv in $all.GetEnumerator()){
  $c = $kv.Value.inputs.host.connection.name
  if($c){
    $key = [regex]::Match($c, "\['([^']+)'\]").Groups[1].Value
    if(-not $census.ContainsKey($key)){ $census[$key] = @() }
    $census[$key] += $kv.Key
  }
}
$declared = @($res.properties.parameters.'$connections'.value.PSObject.Properties.Name)
Write-Host "  declared: $($declared -join ', ')"
foreach($kv in $census.GetEnumerator() | Sort-Object Name){ Write-Host ("  {0,-20} {1} -> {2}" -f $kv.Key, @($kv.Value).Count, (@($kv.Value) -join ', ')) }
foreach($u in $census.Keys){ if($u -notin $declared){ Bad "uses undeclared connection '$u'" } }
foreach($d in $declared){ if($d -notin $census.Keys){ Bad "declared but unused: '$d'" } }
if($script:fail -eq 0){ Ok "connection set consistent" }

Write-Host "`n================ $(if($fail -eq 0){'ALL CHECKS PASSED'}else{"$fail FAILURE(S)"}) ================"
exit $fail

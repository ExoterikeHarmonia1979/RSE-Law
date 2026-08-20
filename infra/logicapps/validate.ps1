#requires -Version 7
param([string]$Path = "C:\Development\REPO\RSE-Law\infra\logicapps\HTTP-Matter-On-Email-Receipt.after.json")
$ErrorActionPreference='Stop'
$raw = Get-Content $Path -Raw
$res = $raw | ConvertFrom-Json
$def = $res.properties.definition
$fail = 0
function Bad($m){ $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Ok($m){ Write-Host "  ok    $m" -ForegroundColor Green }

# ---- collect every action name + verify runAfter only names siblings
$all=@{}
function Walk($actions,$scopeName){
  $sib = @($actions.PSObject.Properties.Name)
  foreach($pr in $actions.PSObject.Properties){
    $n=$pr.Name; $a=$pr.Value
    if($all.ContainsKey($n)){ Bad "duplicate action name '$n'" }
    $all[$n]=$a
    foreach($pr2 in @($a.runAfter.PSObject.Properties)){
      $ra = $pr2.Name
      if($ra -and $ra -notin $sib){ Bad "runAfter '$ra' on '$n' is not a sibling in $scopeName" }
      # Must be an ARRAY of statuses. A bare string deploys as far as ARM and no further:
      #   Error converting value "Succeeded" to type FlowStatus[]
      # PowerShell unwraps single-element arrays on return, so the emit side can produce
      # this without anyone touching the definition. Cheap to assert, invisible otherwise.
      if($null -ne $pr2.Value -and $pr2.Value -isnot [object[]]){
        Bad "runAfter '$ra' on '$n' is the scalar '$($pr2.Value)', not an array - ARM will reject this"
      }
    }
    if($a.actions){ Walk $a.actions "$scopeName/$n" }
    if($a.else.actions){ Walk $a.else.actions "$scopeName/$n/else" }
  }
}
Write-Host "`n[1] runAfter graph"
Walk $def.actions "root"
Ok "$($all.Count) actions walked"

# ---- no reference to any action that no longer exists
Write-Host "`n[2] orphaned expression references"
$refd = [regex]::Matches($raw,"(?:outputs|body|actions)\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach($r in $refd){ if(-not $all.ContainsKey($r)){ Bad "expression references missing action '$r'" } }
if($script:fail -eq 0){ Ok "all $($refd.Count) referenced actions exist" }

# ---- items('loop') targets exist and are Foreach
foreach($m in ([regex]::Matches($raw,"items\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)){
  if(-not $all.ContainsKey($m)){ Bad "items('$m') targets missing action" }
  elseif($all[$m].type -ne 'Foreach'){ Bad "items('$m') targets a $($all[$m].type), not Foreach" }
  else { Ok "items('$m') -> Foreach" }
}

# ---- functions that look like expressions but are actually ACTIONS in Logic Apps
Write-Host "`n[2b] invalid expression functions"
$notFunctions = @('filter','select','join_array','map','where','orderby')
function ScanExpr($o,$path){
  if($o -is [string]){
    if($o.StartsWith('@') -or $o -match '@\{'){
      foreach($f in $notFunctions){
        if($o -match "(?<![A-Za-z_])$f\s*\("){ Bad "$path uses '$f(' as an expression; it is an action, not a function" }
      }
    }
  } elseif($o -is [System.Management.Automation.PSCustomObject]){
    foreach($pr in $o.PSObject.Properties){ ScanExpr $pr.Value "$path.$($pr.Name)" }
  } elseif($o -is [System.Collections.IEnumerable]){
    $i=0; foreach($x in $o){ ScanExpr $x "$path[$i]"; $i++ }
  }
}
ScanExpr $def 'definition'
Ok "no action-only functions used as expressions"

# ---- Query/Select actions have the right input shape
Write-Host "`n[2c] Query/Select shapes"
foreach($kv in $all.GetEnumerator()){
  if($kv.Value.type -eq 'Query'){
    if(-not $kv.Value.inputs.from -or -not $kv.Value.inputs.where){ Bad "Query '$($kv.Key)' needs from+where" } else { Ok "Query $($kv.Key)" }
  }
  if($kv.Value.type -eq 'Select'){
    if(-not $kv.Value.inputs.from -or -not $kv.Value.inputs.select){ Bad "Select '$($kv.Key)' needs from+select" } else { Ok "Select $($kv.Key)" }
  }
}

# ---- the things that MUST be gone
Write-Host "`n[3] removals"
$mustGo = @('Create_Email_File','Create_file_New_Site','Create_Microsoft_365_Group','Get_Field_List','Get_Field_List_1',
  'Join_hub_site','Create_new_folder','Http_Request_to_check_if_SP_Site_Exists','Send_an_email_New_Site_Created',
  'Delay_1_Minute','Delay_5_minutes','Terminate_1','Update_item','Update_item_1','Update_item_Attachment',
  'Update_item_Attachment-copy','HTTP_Get_Access_Token','Get_Client_Secret',
  'HTTP_Graph_API_Call_to_Move_Email_Message','HTTP_Graph_API_Call_to_Move_Email_Message_1')
foreach($g in $mustGo){
  if($all.ContainsKey($g)){ Bad "'$g' still present" }
  if($raw -match [regex]::Escape($g)){ Bad "'$g' still referenced in text" }
}
if($script:fail -eq 0 -or $true){ Ok "checked $($mustGo.Count) removed names" }
foreach($pat in @('Create_.*_Column_in_Documents','Add_.*_Column_to_View','Filter_array_.*_Column','If_No_.*Column')){
  $hit = $all.Keys | Where-Object { $_ -match $pat }
  if($hit){ Bad "column scaffolding remains: $($hit -join ', ')" }
}
Ok "no column/view scaffolding"

# ---- the things that MUST survive
Write-Host "`n[4] survivors"
foreach($k in @('Get_items_In_LookUp_List','Get_items_In_LookUp_List_By_Subject_Word','Create_blob_1','Create_blob_for_Attachment',
                'Set_variable_strFoundMatter','Set_variable_strFoundMatter_1','HTTP_Az_Func_Reg_Matter_Full_Subject_')){
  if($all.ContainsKey($k)){ Ok "$k present" } else { Bad "$k MISSING" }
}

# ---- connector census
Write-Host "`n[5] connector census"
$census=@{}
foreach($kv in $all.GetEnumerator()){
  $c=$kv.Value.inputs.host.connection.name
  if($c){
    $key = [regex]::Match($c, "\['([^']+)'\]").Groups[1].Value
    if(-not $census.ContainsKey($key)){ $census[$key] = @() }
    $census[$key] += $kv.Key
  }
}
foreach($kv in $census.GetEnumerator() | Sort-Object Name){
  Write-Host ("  {0,-20} {1}  -> {2}" -f $kv.Key, @($kv.Value).Count, (@($kv.Value) -join ', '))
}
$spActions = @($census['sharepointonline'])
if(($spActions | Sort-Object) -join ',' -eq 'Get_items_In_LookUp_List,Get_items_In_LookUp_List_By_Subject_Word'){
  Ok "only the two matter lookups use SharePoint"
} else { Bad "unexpected SharePoint actions: $($spActions -join ', ')" }
foreach($k in $census.Keys){ if($k -like 'sharepointonline-*' -or $k -eq 'office365-1'){ Bad "connection '$k' still used" } }

# ---- connections declared vs used
Write-Host "`n[6] `$connections"
$declared = @($res.properties.parameters.'$connections'.value.PSObject.Properties.Name)
Write-Host "  declared: $($declared -join ', ')"
foreach($u in $census.Keys){ if($u -notin $declared){ Bad "uses undeclared connection '$u'" } }
foreach($d in $declared){ if($d -notin $census.Keys -and $d -ne 'servicebus'){ Bad "declared but unused: '$d'" } }
Ok "connection set consistent"

# ---- durability + auth
Write-Host "`n[7] durability / auth"
$tn = @($def.triggers.PSObject.Properties.Name)[0]
if($tn -match 'peek-lock'){ Ok "trigger is $tn" } else { Bad "trigger is $tn" }
if($def.triggers.$tn.inputs.path -match 'head/peek'){ Ok "trigger path uses head/peek" } else { Bad "trigger path: $($def.triggers.$tn.inputs.path)" }
Write-Host "  trigger concurrency runs = $($def.triggers.$tn.runtimeConfiguration.concurrency.runs)"
foreach($k in @('Complete_the_message_in_a_queue','Abandon_the_message_in_a_queue')){
  if($all.ContainsKey($k)){ Ok "$k present ($($all[$k].inputs.method.ToUpper()) $($all[$k].inputs.path))" } else { Bad "$k missing" }
}
$terms = $all.Keys | Where-Object { $all[$_].type -eq 'Terminate' }
Write-Host "  Terminate actions: $($terms -join ', ')"
foreach($t in $terms){ if($t -notin @('Terminate_Failed','Terminate_Stale_Handled')){ Bad "Terminate '$t' would bypass Complete/Abandon" } }
# every Terminate must come after the message has been dealt with
foreach($t in $terms){
  $pre = @($all[$t].runAfter.PSObject.Properties.Name)
  if(-not ($pre | Where-Object { $_ -match 'Complete|Abandon' })){ Bad "Terminate '$t' does not follow a Complete/Abandon" }
  else { Ok "Terminate $t follows $($pre -join ',')" }
}
if($raw -match 'client_secret=[A-Za-z0-9~._-]{8,}'){ Bad "literal client secret present" } else { Ok "no literal client secret" }
$graphMI = $all.Keys | Where-Object { $all[$_].type -eq 'Http' -and $all[$_].inputs.uri -match 'graph\.microsoft\.com' }
foreach($g in $graphMI){
  $au=$all[$g].inputs.authentication.type
  if($au -eq 'ManagedServiceIdentity'){ Ok "$g uses MI" } else { Bad "$g auth = '$au'" }
  if($all[$g].inputs.headers.Authorization){ Bad "$g still sets an Authorization header" }
}

# ---- races
Write-Host "`n[8] append races"
foreach($kv in $all.GetEnumerator()){
  if($kv.Value.type -notin @('AppendToArrayVariable','AppendToStringVariable')){ continue }
  $owner = $all.Keys | Where-Object { $all[$_].type -eq 'Foreach' -and ($all[$_].actions.PSObject.Properties.Name -contains $kv.Key) }
  if(-not $owner){ Write-Host "  $($kv.Key): not directly in a Foreach"; continue }
  $c = $all[$owner].runtimeConfiguration.concurrency.repetitions
  if($c -eq 1){ Ok "$($kv.Key) in $owner (sequential)" } else { Bad "$($kv.Key) in $owner concurrency=$(if($c){$c}else{'default 20'})" }
}

# ---- blob targets
Write-Host "`n[9] blob targets"
foreach($b in ($all.Keys | Where-Object { $all[$_].inputs.host.connection.name -match 'azureblob' })){
  Write-Host "  $b -> $($all[$b].inputs.queries.folderPath)"
  Write-Host "        name = $($all[$b].inputs.queries.name)"
}

Write-Host "`n================ $(if($fail -eq 0){'ALL CHECKS PASSED'}else{"$fail FAILURE(S)"}) ================"
exit $fail

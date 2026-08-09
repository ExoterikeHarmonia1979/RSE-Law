#requires -Version 7
<#
Shared drift detection for HTTP-Matter-On-Email-Receipt. Dot-sourced by deploy.ps1
(refuses to PUT over drift) and transform.ps1 (refuses to regenerate after.json over
drift). Both need the identical comparison, so it lives in one place - two copies of
this would diverge and then disagree about whether production had been edited.

"Drift" means: the live workflow differs from deployed.json, the definition as
deploy.ps1 last PUT it. That is the only comparison that detects an out-of-band
portal edit. Comparing live against the *new* definition cannot, because every
intentional change is also a difference.
#>

# Returned by ARM but never authored by us - comparing it reports drift on every run.
$script:DriftComputedKeys = @('evaluatedRecurrence')

<#
Scalars must be recognised before the object test, and arrays must be walked with
foreach rather than ForEach-Object.

Both rules exist for the same reason: the pipeline hands a function a PSObject-wrapped
element, and a wrapped string DOES satisfy -is [pscustomobject] even though a bare one
does not. Recursing through a pipeline therefore turns "Succeeded" into the object
{"Length":9} - its only visible property - silently rewriting every runAfter status
and JSON-schema required list in the definition.
#>
function Test-JsonScalar($o) {
  if ($null -eq $o) { return $true }
  $base = if ($o -is [psobject]) { $o.psobject.BaseObject } else { $o }
  return ($base -is [string]) -or ($base -is [valuetype])
}

function Get-DriftCanon($o) {
  if (Test-JsonScalar $o) { return $o }
  if ($o -is [System.Collections.IDictionary]) {
    $out = [ordered]@{}
    foreach ($k in ($o.Keys | Sort-Object)) {
      if ($script:DriftComputedKeys -contains $k) { continue }
      $out[$k] = Get-DriftCanon $o[$k]
    }
    return $out
  }
  if ($o -is [System.Collections.IEnumerable]) {
    $acc = @(); foreach ($item in $o) { $acc += ,(Get-DriftCanon $item) }; return $acc
  }
  if ($o -is [pscustomobject]) {
    $out = [ordered]@{}
    foreach ($k in ($o.PSObject.Properties.Name | Sort-Object)) {
      if ($script:DriftComputedKeys -contains $k) { continue }
      $out[$k] = Get-DriftCanon $o.$k
    }
    return $out
  }
  return $o
}
function Get-DriftJson($o) { Get-DriftCanon $o | ConvertTo-Json -Depth 100 -Compress }

# Walk two trees and collect differing paths, so callers can name the setting that
# moved rather than dumping 60KB of JSON at whoever is deploying.
function Add-DriftPaths($a, $b, $path, [ref]$acc) {
  if ($acc.Value.Count -ge 40) { return }
  if ($a -is [pscustomobject] -and $b -is [pscustomobject]) {
    $keys = @($a.PSObject.Properties.Name) + @($b.PSObject.Properties.Name) | Sort-Object -Unique
    foreach ($k in $keys) {
      if ($script:DriftComputedKeys -contains $k) { continue }
      $hasA = $a.PSObject.Properties.Name -contains $k
      $hasB = $b.PSObject.Properties.Name -contains $k
      # $a is live, $b is baseline - keep these the right way round, a swapped label
      # sends whoever is deploying looking for the change in the wrong place
      if (-not $hasA) { $acc.Value.Add("$path.$k : missing from live, present in baseline"); continue }
      if (-not $hasB) { $acc.Value.Add("$path.$k : present on live only, not in baseline"); continue }
      Add-DriftPaths $a.$k $b.$k "$path.$k" $acc
    }
    return
  }
  if ($a -is [object[]] -and $b -is [object[]]) {
    if ($a.Count -ne $b.Count) { $acc.Value.Add("$path : array length $($a.Count) vs $($b.Count)"); return }
    for ($i = 0; $i -lt $a.Count; $i++) { Add-DriftPaths $a[$i] $b[$i] "$path[$i]" $acc }
    return
  }
  if ((Get-DriftJson $a) -ne (Get-DriftJson $b)) {
    $av = "$a"; $bv = "$b"
    if ($av.Length -gt 60) { $av = $av.Substring(0,60) + '...' }
    if ($bv.Length -gt 60) { $bv = $bv.Substring(0,60) + '...' }
    $acc.Value.Add("$path : live='$av' baseline='$bv'")
  }
}

<#
Recursively key-sort anything destined for ConvertTo-Json, so emitting the same
definition twice produces the same bytes.

ConvertFrom-Json -AsHashtable yields unordered hashtables, so without this every
regeneration reshuffles keys and produces ~538 changed lines for a one-line edit.
That is not cosmetic: a real change is unreviewable inside that much noise, which is
how a live-vs-repo concurrency difference gets through a diff unnoticed.

Unlike Get-DriftCanon this drops nothing - it is for emission, not comparison.
#>
function Sort-JsonKeys($o) {
  # scalar first, and foreach below rather than ForEach-Object - see Test-JsonScalar
  if (Test-JsonScalar $o) { return $o }
  if ($o -is [System.Collections.IDictionary]) {
    $out = [ordered]@{}
    foreach ($k in ($o.Keys | Sort-Object)) { $out[$k] = Sort-JsonKeys $o[$k] }
    return $out
  }
  if ($o -is [System.Collections.IEnumerable]) {
    $acc = @(); foreach ($item in $o) { $acc += ,(Sort-JsonKeys $item) }; return $acc
  }
  if ($o -is [pscustomobject]) {
    $out = [ordered]@{}
    foreach ($k in ($o.PSObject.Properties.Name | Sort-Object)) { $out[$k] = Sort-JsonKeys $o.$k }
    return $out
  }
  return $o
}

function Get-LiveWorkflow {
  param([string]$ResourceGroup = 'Sharepoint1', [string]$Workflow = 'HTTP-Matter-On-Email-Receipt')
  $az    = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
  $token = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
  $sub   = (& $az account show --query id -o tsv)
  $uri   = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$Workflow`?api-version=2019-05-01"
  [pscustomobject]@{
    uri      = $uri
    headers  = @{ Authorization = "Bearer $token" }
    workflow = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }
  }
}

<#
Returns: Checked (did the comparison actually happen), Reason (why not, if not),
Drift (list of differing paths), Live (the ARM object, so callers need not refetch).

Deliberately reports Checked=$false rather than throwing when the baseline is absent
or Azure is unreachable: authoring the definition offline has to stay possible. The
caller decides whether an unverifiable state is fatal.
#>
function Test-WorkflowDrift {
  param(
    [string]$BaselinePath,
    [string]$ResourceGroup = 'Sharepoint1',
    [string]$Workflow      = 'HTTP-Matter-On-Email-Receipt'
  )
  $drift = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path $BaselinePath)) {
    return [pscustomobject]@{ Checked = $false; Reason = "no baseline at $BaselinePath"; Drift = $drift; Live = $null }
  }
  try { $live = Get-LiveWorkflow -ResourceGroup $ResourceGroup -Workflow $Workflow }
  catch { return [pscustomobject]@{ Checked = $false; Reason = "could not reach Azure: $($_.Exception.Message)"; Drift = $drift; Live = $null } }

  $baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json
  Add-DriftPaths $live.workflow.properties.definition $baseline.definition 'definition' ([ref]$drift)
  Add-DriftPaths $live.workflow.properties.parameters $baseline.parameters 'parameters' ([ref]$drift)
  [pscustomobject]@{ Checked = $true; Reason = ''; Drift = $drift; Live = $live }
}

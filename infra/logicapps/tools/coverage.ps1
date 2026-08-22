#requires -Version 7
# Test the shipped pattern arrays against the current list data, and shape-profile whatever
# they miss. Patterns are read out of the .cs files so this tests what actually ships.
param([switch]$ShowShapes)
$ErrorActionPreference = 'Stop'
$sp   = $PSScriptRoot
$repo = 'C:\Development\REPO\RSE-Law\RegExAzFunc'

function Get-Patterns($file){
  $raw = Get-Content $file -Raw
  [regex]::Matches($raw, '@"((?:[^"]|"")*)"') | ForEach-Object { $_.Groups[1].Value -replace '""','"' }
}
function Get-Shape($s){
  ($s.ToCharArray() | ForEach-Object {
    if($_ -cmatch '[A-Za-z]'){ 'A' } elseif($_ -match '\d'){ '9' } else { $_ }
  }) -join '' -replace '(A)\1+','A+' -replace '(9)\1+','9+'
}

$items = Get-Content "$sp\list-dump.json" -Raw | ConvertFrom-Json

function Test-Set($name, $values, $patternFile){
  $pats = @(Get-Patterns $patternFile)
  $vals = @($values | ForEach-Object { "$_".Trim().ToUpper() } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
  $unmatched = @()
  $hits = @{}; foreach($p in $pats){ $hits[$p] = 0 }
  foreach($v in $vals){
    $any = $false
    foreach($p in $pats){ if($v -cmatch $p){ $hits[$p]++; $any = $true } }
    if(-not $any){ $unmatched += $v }
  }
  $cov = if($vals.Count){ [math]::Round(100 * ($vals.Count - $unmatched.Count) / $vals.Count, 2) } else { 0 }
  Write-Host "`n=== $name ===" -ForegroundColor Cyan
  Write-Host "patterns=$($pats.Count)  distinct values=$($vals.Count)  covered=$($vals.Count - $unmatched.Count)  ($cov%)  UNMATCHED=$($unmatched.Count)"
  $i = 0
  foreach($p in $pats){ Write-Host ("  [{0,2}] {1,5} hits  {2}" -f $i++, $hits[$p], $p) }
  if($unmatched.Count){
    Write-Host "`n  unmatched values grouped by shape:" -ForegroundColor Yellow
    $unmatched | Group-Object { Get-Shape $_ } | Sort-Object Count -Descending | ForEach-Object {
      $ex = ($_.Group | Select-Object -First 4) -join ', '
      Write-Host ("   {0,4}x  {1,-24} e.g. {2}" -f $_.Count, $_.Name, $ex)
    }
  }
  return [pscustomobject]@{ Name=$name; Values=$vals; Unmatched=$unmatched; Patterns=$pats }
}

$r1 = Test-Set 'RSEFileNo' ($items | ForEach-Object { $_.RSEFileNo }) "$repo\RSEFileNoPatterns.cs"
$caseClaim = @($items | ForEach-Object { $_.CaseNo }) + @($items | ForEach-Object { $_.ClaimNo })
$r2 = Test-Set 'CaseNo + ClaimNo' $caseClaim "$repo\CaseClaimNoPatterns.cs"

if($ShowShapes){
  Write-Host "`n=== full shape profile: CaseNo+ClaimNo ===" -ForegroundColor Cyan
  $r2.Values | Group-Object { Get-Shape $_ } | Sort-Object Count -Descending | Select-Object -First 40 |
    ForEach-Object { "{0,5}x  {1,-28} {2}" -f $_.Count, $_.Name, (($_.Group | Select-Object -First 2) -join ', ') }
}
$r1.Unmatched | Set-Content "$sp\unmatched-rsefileno.txt"
$r2.Unmatched | Set-Content "$sp\unmatched-caseclaim.txt"

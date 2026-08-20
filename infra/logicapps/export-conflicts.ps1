#requires -Version 7
<#
Export the claim-number conflicts Matters-Lookup-Sync deliberately will not resolve:
matters where the intake spreadsheet carries a claim number and the Matters Lookup list
already holds a DIFFERENT non-blank one. The sync fills blanks only and never overwrites,
so every row here is waiting on a human decision. Each run reports the same count as
`claimConflictsLeftAlone`; this turns that number into something workable.

  ./export-conflicts.ps1                          # dated .xlsx in the current directory
  ./export-conflicts.ps1 -OutFile C:\some\where.xlsx

The output contains client names and matter numbers. Keep it out of the repo - the last
one was written to OutlookSearchSPFxWebPart/FIles/, which .gitignore already excludes.

Two things here look roundabout and are not:

**The list is read through a throwaway Logic App.** The interactive `az` sign-in cannot
read this list - Graph returns 403 on the lists collection and enumerates zero lists,
because the CLI's delegated token carries no Sites.* scope. The `sharepointonline` API
connection can read it, and does so in production every 15 minutes. So this stands up a
one-action workflow against that connection, invokes it, and deletes it in a finally.

**The .xlsx is emitted as OOXML by hand rather than through Excel.** Excel COM automation
is installed on this machine but non-functional: `Workbooks.Add()` returns null, so Excel
cannot even create a file, let alone open one. Writing the package directly needs no Excel
and has no such dependency. Verified with openpyxl - parses, both sheets, correct row
count, autofilter, freeze pane, and a genuinely numeric ID column.
#>
param(
  [string]$OutFile = (Join-Path (Get-Location) "Matters Lookup - Claim Number Conflicts $(Get-Date -Format 'yyyy-MM-dd').xlsx"),
  [string]$ResourceGroup = 'Sharepoint1',
  [string]$SiteUrl  = 'https://reiszsidermaneisenberg.sharepoint.com/sites/MatterExchange-POC',
  [string]$ListGuid = '940d4826-7cf4-4bf1-979e-f6d28f4ba1c9',
  [string]$WorkbookDriveId = 'b!3WCB7F4QOUy0ctjm7GNwCLwPAJi3WCNEr2GHuU7AbZ9EePhTjn9vRID5-M4AJs2V',
  [string]$WorkbookItemId  = '0173CEA2QC7KJILOCGPRE2RIRAOROJVQV4',
  [string]$WorkbookTable   = 'List26'
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"   # per-user ZIP install, not on PATH

# ------------------------------------------------- the list, via a disposable workflow
function Get-LookupListItems {
  param([string]$ResourceGroup, [string]$SiteUrl, [string]$ListGuid)
  $sub = (& $az account show --query id -o tsv)
  $wf  = "tmp-export-conflicts-$([guid]::NewGuid().ToString('N').Substring(0,6))"
  $tok = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
  $H   = @{ Authorization = "Bearer $tok" }
  $uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$wf`?api-version=2016-06-01"
  $conn = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Web/connections/sharepointonline"

  $body = @{
    location = 'eastus'
    properties = @{
      state = 'Enabled'
      definition = @{
        '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
        contentVersion = '1.0.0.0'
        parameters = @{ '$connections' = @{ defaultValue = @{}; type = 'Object' } }
        triggers = @{ manual = @{ type = 'Request'; kind = 'Http'; inputs = @{ schema = @{} } } }
        actions = @{
          Get_items = @{
            runAfter = @{}; type = 'ApiConnection'
            inputs = @{
              host = @{ connection = @{ name = "@parameters('`$connections')['sharepointonline']['connectionId']" } }
              method = 'get'
              path = "/datasets/@{encodeURIComponent(encodeURIComponent('$SiteUrl'))}/tables/@{encodeURIComponent(encodeURIComponent('$ListGuid'))}/items"
              queries = @{ '$top' = 5000 }
            }
            runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 5000 } }
          }
          Slim = @{
            runAfter = @{ Get_items = @('Succeeded') }; type = 'Select'
            inputs = @{
              from = "@body('Get_items')?['value']"
              select = @{ ID = "@item()?['ID']"; RSEFileNo = "@item()?['RSEFileNo']"; CaseNo = "@item()?['CaseNo']"; ClaimNo = "@item()?['ClaimNo']" }
            }
          }
          Response = @{
            runAfter = @{ Slim = @('Succeeded') }; type = 'Response'; kind = 'Http'
            inputs = @{ statusCode = 200; body = "@body('Slim')" }
          }
        }
      }
      parameters = @{ '$connections' = @{ value = @{ sharepointonline = @{
        connectionId = $conn; connectionName = 'sharepointonline'
        id = "/subscriptions/$sub/providers/Microsoft.Web/locations/eastus/managedApis/sharepointonline"
      } } } }
    }
  } | ConvertTo-Json -Depth 40

  try {
    Invoke-RestMethod -Method Put -Uri $uri -Headers $H -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    $cb = Invoke-RestMethod -Method Post -Headers $H -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$wf/triggers/manual/listCallbackUrl?api-version=2016-06-01"
    Invoke-RestMethod -Method Post -Uri $cb.value -ContentType 'application/json' -Body '{}'
  } finally {
    try { Invoke-RestMethod -Method Delete -Uri $uri -Headers $H | Out-Null } catch { Write-Warning "could not delete $wf - remove it by hand" }
  }
}

# --------------------------------------------------------------- the sheet, via Graph
function Get-SheetRows {
  $tok = (& $az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
  $cols = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $tok" } -Uri `
    "https://graph.microsoft.com/v1.0/drives/$WorkbookDriveId/items/$WorkbookItemId/workbook/tables/$WorkbookTable/columns?`$select=name,values").value
  function C($n){
    $v = ($cols | Where-Object name -eq $n).values
    if(-not $v){ throw "column '$n' not found in table '$WorkbookTable' - was it renamed?" }
    $v
  }
  $f = C 'RSE File #'; $c = C 'Claim Number'; $a = C 'Attorney Assigned'; $r = C 'RSE Client'
  $rows = [ordered]@{}
  for($i = 1; $i -lt $f.Count; $i++){
    $k = "$($f[$i][0])".Trim()
    if($k -ne '' -and -not $rows.Contains($k)){
      $rows[$k] = [pscustomobject]@{
        Claim    = "$($c[$i][0])".Trim()
        Attorney = ("$($a[$i][0])".Trim() -replace '\s+',' ')
        Client   = ("$($r[$i][0])".Trim() -replace '\s+',' ')
      }
    }
  }
  $rows
}

# ----------------------------------------------------------------------- xlsx writing
function Esc($s){
  $t = "$s" -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]',''
  $t.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}
function ColLetter([int]$i){ $s = ''; while($i -gt 0){ $m = ($i - 1) % 26; $s = [char](65 + $m) + $s; $i = [int](($i - $m) / 26) }; $s }
function XlRow($n, $cells, $height){
  $h = if($height){ " ht=""$height"" customHeight=""1""" } else { '' }
  $sb = "<row r=""$n""$h>"; $c = 1
  foreach($cell in $cells){
    $ref = "$(ColLetter $c)$n"
    $st  = if($cell.s){ " s=""$($cell.s)""" } else { '' }
    if($null -ne $cell.num){ $sb += "<c r=""$ref""$st><v>$($cell.num)</v></c>" }
    elseif("$($cell.v)" -ne ''){ $sb += "<c r=""$ref""$st t=""inlineStr""><is><t xml:space=""preserve"">$(Esc $cell.v)</t></is></c>" }
    $c++
  }
  "$sb</row>"
}

# ------------------------------------------------------------------------------- pull
Write-Host "reading the lookup list ..."
$list = Get-LookupListItems -ResourceGroup $ResourceGroup -SiteUrl $SiteUrl -ListGuid $ListGuid
Write-Host "  $($list.Count) items"
Write-Host "reading the intake sheet ..."
$sheet = Get-SheetRows
Write-Host "  $($sheet.Count) distinct file numbers"

$byFile = @{}
foreach($it in $list){ $k = "$($it.RSEFileNo)".Trim(); if($k -ne '' -and -not $byFile.ContainsKey($k)){ $byFile[$k] = $it } }

# pattern [0] from RegExAzFunc/CaseClaimNoPatterns.cs - the CA short-form court case no
$caCaseNo = '^\d{1,4}[A-Z]{2,5}-?\d{3,6}[A-Z]?$'

$rows = @()
foreach($k in $sheet.Keys){
  $sc = $sheet[$k].Claim
  if($sc -eq '' -or -not $byFile.ContainsKey($k)){ continue }
  $it = $byFile[$k]
  $lc = "$($it.ClaimNo)".Trim(); $cn = "$($it.CaseNo)".Trim()
  if($lc -eq '' -or $lc -eq $sc){ continue }   # blanks are filled automatically; agreement needs nothing

  $cat, $action = if($cn -ne '' -and $cn -eq $sc){
    'Columns reversed', 'The sheet value is ALREADY in CaseNo, and ClaimNo holds something else - usually the court case number. Decide which column each belongs in; do not simply overwrite.'
  } elseif($sc.StartsWith("$lc-")){
    'Suffix drift', 'Sheet value is the list value plus a reopen/sequence suffix, so the sheet looks more current. Safe to adopt if that suffix means something to you.'
  } elseif($lc.StartsWith("$sc-")){
    'Suffix drift (list newer)', 'List value is the sheet value plus a suffix - here the LIST looks more current. Consider fixing the spreadsheet instead.'
  } elseif($cn -eq ''){
    'CaseNo blank', 'CaseNo is empty, so the current ClaimNo is the only copy of that token. Overwriting removes it from matching entirely.'
  } else {
    'Conflicting values', 'Both fields hold values and neither matches the sheet. Needs a look at the matter.'
  }

  $rows += [pscustomobject]@{
    'RSE File No'            = $k
    'Category'               = $cat
    'List ClaimNo (current)' = $lc
    'List CaseNo (current)'  = $cn
    'Sheet Claim Number'     = $sc
    'ClaimNo looks like a court case no' = if($lc.ToUpper() -cmatch $caCaseNo){ 'Yes' } else { 'No' }
    'Suggested action'       = $action
    'Attorney Assigned'      = $sheet[$k].Attorney
    'RSE Client'             = $sheet[$k].Client
    'List Item ID'           = [int]$it.ID
    'Open item'              = "$SiteUrl/Lists/Matters%20Lookup/DispForm.aspx?ID=$($it.ID)"
  }
}
$rows = @($rows | Sort-Object Category, 'RSE File No')
if($rows.Count -eq 0){ Write-Host "`nno conflicts - nothing to export"; return }
Write-Host "`nconflicts: $($rows.Count)"
$byCat = $rows | Group-Object Category | Sort-Object Count -Descending
$byCat | ForEach-Object { "  {0,4}  {1}" -f $_.Count, $_.Name }

# ------------------------------------------------------------------------ sheet: data
$headers = @($rows[0].PSObject.Properties.Name)
$nCols = $headers.Count; $nRows = $rows.Count + 1
$lastCol = ColLetter $nCols
$widths = @(13,26,26,26,34,17,64,22,46,12,48)
# parenthesise the join: '<cols>' + $array -join '' binds as ('<cols>' + $array) -join '',
# which stringifies the array with spaces and swallows the closing tag as the separator
$colXml = '<cols>' + ((1..$nCols | ForEach-Object { "<col min=""$_"" max=""$_"" width=""$($widths[$_-1])"" customWidth=""1""/>" }) -join '') + '</cols>'

$data = [Text.StringBuilder]::new()
[void]$data.Append((XlRow 1 ($headers | ForEach-Object { @{ v = $_; s = 1 } }) 32))
$r = 2
foreach($row in $rows){
  $cells = foreach($h in $headers){
    if($h -eq 'List Item ID'){ @{ num = $row.$h } }
    elseif($h -in @('Suggested action','RSE Client')){ @{ v = $row.$h; s = 2 } }
    else { @{ v = $row.$h } }
  }
  [void]$data.Append((XlRow $r $cells)); $r++
}
$sheet2 = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  "<worksheet xmlns=""http://schemas.openxmlformats.org/spreadsheetml/2006/main""><dimension ref=""A1:$lastCol$nRows""/><sheetViews><sheetView workbookViewId=""0""><pane ySplit=""1"" topLeftCell=""A2"" activePane=""bottomLeft"" state=""frozen""/><selection pane=""bottomLeft"" activeCell=""A2"" sqref=""A2""/></sheetView></sheetViews><sheetFormatPr defaultRowHeight=""15""/>$colXml<sheetData>$($data.ToString())</sheetData><autoFilter ref=""A1:$lastCol$nRows""/></worksheet>"

# --------------------------------------------------------------------- sheet: summary
$sum = @(
  @{ a='Claim-number conflicts in the Matters Lookup list'; b=''; s=3 },
  @{ a='Generated'; b=(Get-Date).ToString('yyyy-MM-dd HH:mm') },
  @{ a=''; b='' },
  @{ a='What this is'; b='Matters where the intake spreadsheet carries a claim number and the Matters Lookup list already holds a DIFFERENT non-blank one. Matters-Lookup-Sync fills blank claim numbers only and never overwrites, so none of these rows were touched by it.' },
  @{ a='Why not automatic'; b='In most of these the list ClaimNo holds the COURT CASE NUMBER while CaseNo holds the insurer claim - the two columns are reversed relative to what the spreadsheet means by them. Overwriting would delete a token the email archive matches subjects against, so it needs a person to rule on it.' },
  @{ a='How to use it'; b='Work the "Claim conflicts" tab by Category. "Open item" links straight to the list row. Deciding a whole category at once is likely faster than going matter by matter.' },
  @{ a=''; b='' },
  @{ a='Total conflicts'; b="$($rows.Count)"; s=4 }
)
foreach($g in $byCat){ $sum += @{ a="   $($g.Name)"; b="$($g.Count)" } }
$sum += @{ a=''; b='' }
$sum += @{ a='Not included'; b='Blank claim numbers are filled automatically and need no decision. Rows where the sheet and list already agree are not listed. Both are re-checked every 15 minutes.' }

$sd = [Text.StringBuilder]::new(); $r = 1
foreach($line in $sum){
  [void]$sd.Append((XlRow $r @(@{ v=$line.a; s=$(if($line.s){$line.s}else{4}) }, @{ v=$line.b; s=2 }))); $r++
}
$sheet1 = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  "<worksheet xmlns=""http://schemas.openxmlformats.org/spreadsheetml/2006/main""><dimension ref=""A1:B$($sum.Count)""/><sheetViews><sheetView tabSelected=""1"" workbookViewId=""0""/></sheetViews><sheetFormatPr defaultRowHeight=""15""/><cols><col min=""1"" max=""1"" width=""22"" customWidth=""1""/><col min=""2"" max=""2"" width=""105"" customWidth=""1""/></cols><sheetData>$($sd.ToString())</sheetData></worksheet>"

$styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'

# [ordered], not @{}: a plain hashtable does not preserve insertion order, and OPC readers
# expect the content-types stream first in the package.
$parts = [ordered]@{
  '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
  '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
  'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Summary" sheetId="1" r:id="rId1"/><sheet name="Claim conflicts" sheetId="2" r:id="rId2"/></sheets></workbook>'
  'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
  'xl/styles.xml' = $styles
  'xl/worksheets/sheet1.xml' = $sheet1
  'xl/worksheets/sheet2.xml' = $sheet2
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$dir = Split-Path $OutFile -Parent
if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if(Test-Path $OutFile){ Remove-Item $OutFile -Force }
$zip = [IO.Compression.ZipFile]::Open($OutFile, 'Create')
try {
  foreach($name in $parts.Keys){
    $e = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
    $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding($false)))
    $w.Write($parts[$name].Trim()); $w.Flush(); $w.Dispose()
  }
} finally { $zip.Dispose() }

Write-Host "`nwrote $OutFile  ($([math]::Round((Get-Item $OutFile).Length/1KB,1)) KB, $($rows.Count) data rows)"
Write-Host "contains client names and matter numbers - do not commit it"

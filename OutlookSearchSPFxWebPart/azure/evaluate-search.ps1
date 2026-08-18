#requires -Version 7
<#
Measure search quality across configurations, so tuning hybrid search is a comparison
rather than an opinion.

Why this exists: adding a vector query changes results for every search, and the
effect is not uniform. It helps a conceptual question and hurts a name lookup, and
the damage is invisible unless the same queries are run the same way before and
after. Eyeballing a few searches is how a precision regression ships.

Metric is precision@N: of the first N results, how many match that query's relevance
marker. The marker is a regex over the subject - a proxy for human judgement, not a
substitute for it. It is deliberately generous for the conceptual queries, where no
regex can really say whether a result answered the question, so read those rows as
directional and the name and matter-number rows as reliable.

IMPORTANT: results are only meaningful once the vector backfill has finished. While
it is running, the vector half is choosing its nearest k from whatever fraction of
the corpus has been embedded, and every hybrid row understates. The report prints the
backfill percentage for exactly this reason - record it with any result you quote.

  ./evaluate-search.ps1                    # report to the console
  ./evaluate-search.ps1 -SaveAs base.json  # also save, to diff against a later run
#>
param(
  [string]$Service   = 'rse-matterssearch',
  [string]$Group     = 'rg-rse-search-eus',
  [string]$Index     = 'matters-eml-index',
  [string]$ApiVersion = '2024-07-01',
  [int]$Top          = 10,
  [int[]]$KValues    = @(10, 25, 50),
  [string]$SaveAs
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$key = (& $az search admin-key show --service-name $Service --resource-group $Group --query primaryKey -o tsv).Trim()
$h = @{ 'api-key' = $key }
$base = "https://$Service.search.windows.net"
$url = "$base/indexes/$Index/docs/search?api-version=$ApiVersion"

# marker = what counts as a relevant result for this query.
# kind: 'lookup' - the user knows what they want; precision matters most
#       'concept' - a question in words; recall matters and the marker is loose
$queries = @(
  @{ q = 'Stryzhak';                     kind = 'lookup';  marker = 'Stryzhak|Gasparyan' }
  @{ q = 'Hong Chun Li';                 kind = 'lookup';  marker = 'Hong Chun Li|Blue Hill|BHSI' }
  @{ q = '100.077';                      kind = 'lookup';  marker = '100\.077' }
  @{ q = 'Schumacher Manzanero';         kind = 'lookup';  marker = 'Schumacher|Manzanero|06\.183' }
  @{ q = 'meet and confer';              kind = 'concept'; marker = 'meet and confer|confer|interrogator' }
  @{ q = 'motion to compel discovery';   kind = 'concept'; marker = 'compel|discovery|interrogator|produc' }
  @{ q = 'opposing counsel will not produce the documents we requested';
                                         kind = 'concept'; marker = 'compel|produc|subpoena|discovery|interrogator|confer' }
  @{ q = 'scheduling a mediation date';  kind = 'concept'; marker = 'mediat|schedul|hearing|calendar|conference' }
)

<#
Retries on 429. A hybrid query embeds the search text at query time, on the SAME
Azure OpenAI deployment the indexer is using, so while a backfill is running the two
compete for the same tokens-per-minute allowance and the search returns

  "Could not complete vectorization action. The vectorization endpoint returned
   status code '429' (TooManyRequests)."

That is not only this script's problem: a user searching in relevance mode during a
large reindex can be shown the same failure. Worth remembering before starting a
backfill during working hours.
#>
function Search-Index($body) {
  $json = $body | ConvertTo-Json -Depth 8
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      return Invoke-RestMethod -Method Post -Uri $url -Headers $h -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json))
    } catch {
      $throttled = "$($_.ErrorDetails.Message)" -match '429|TooManyRequests'
      if (-not $throttled -or $attempt -eq 5) { throw }
      Start-Sleep -Seconds ([math]::Pow(2, $attempt))
    }
  }
}

function Measure-Config {
  param($query, $marker, [int]$k, [switch]$ByDate)
  $body = @{
    search = $query; queryType = 'full'; searchMode = 'all'
    top = $Top; count = $true; select = 'metadata_subject'
  }
  if ($ByDate) { $body.orderby = 'sent_date desc' }
  if ($k -gt 0) { $body.vectorQueries = , @{ kind = 'text'; text = $query; fields = 'content_vector'; k = $k } }
  $r = Search-Index $body
  $subjects = @($r.value | ForEach-Object { "$($_.metadata_subject)" })
  $rel = @($subjects | Where-Object { $_ -match $marker }).Count
  [pscustomobject]@{
    total = [int]$r.'@odata.count'
    shown = $subjects.Count
    relevant = $rel
    precision = if ($subjects.Count) { [math]::Round($rel / $subjects.Count, 3) } else { 0 }
  }
}

# --- how much of the corpus actually has a vector? every hybrid number depends on it.
#
# Do NOT infer this from the last run's itemsProcessed: once the backfill is done the
# indexer runs hourly over only what changed, so that number is a handful of documents
# and reads as "0.1% complete" on a fully populated index. Vector index size is the
# honest measure - it accumulates and does not reset per run.
$status = (Invoke-RestMethod -Uri "$base/indexers/matters-eml-indexer/status?api-version=$ApiVersion" -Headers $h).lastResult
$docs = (Invoke-RestMethod -Uri "$base/indexes/$Index/stats?api-version=$ApiVersion" -Headers $h).documentCount
$vecMB = (Invoke-RestMethod -Uri "$base/servicestats?api-version=$ApiVersion" -Headers $h).counters.vectorIndexSize.usage / 1MB
$expectMB = $docs * 1536 * 4 / 1MB     # dimensions x 4 bytes per float
$coverage = if ($expectMB) { [math]::Round(100 * $vecMB / $expectMB, 1) } else { 0 }
Write-Host ""
Write-Host "Search quality report  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
Write-Host "index $Index : $docs documents"
Write-Host ("vector coverage: {0:N1} MB of ~{1:N0} MB expected ({2}%)   last run: {3}, {4} processed, {5} failed" -f `
  $vecMB, $expectMB, $coverage, $status.status, $status.itemsProcessed, $status.itemsFailed)
if ($coverage -lt 80) {
  Write-Host "WARNING: vector coverage low - every hybrid row below understates. Re-run when the backfill finishes." -ForegroundColor Yellow
}
Write-Host ""

$configs = @(@{ label = 'keyword'; k = 0 }) + @($KValues | ForEach-Object { @{ label = "hybrid k=$_"; k = $_ } })
$rows = @()

foreach ($sort in @('relevance', 'date')) {
  Write-Host ("--- sorted by $sort " + ('-' * 46))
  $hdr = "{0,-52} {1,-6}" -f 'query', 'kind'
  foreach ($c in $configs) { $hdr += "{0,-13}" -f $c.label }
  Write-Host $hdr -ForegroundColor DarkGray

  foreach ($item in $queries) {
    $line = "{0,-52} {1,-6}" -f $item.q.Substring(0, [Math]::Min(50, $item.q.Length)), $item.kind
    foreach ($c in $configs) {
      $m = if ($sort -eq 'date') { Measure-Config $item.q $item.marker $c.k -ByDate }
           else                  { Measure-Config $item.q $item.marker $c.k }
      $line += "{0,-13}" -f ("$($m.relevant)/$($m.shown)")
      $rows += [pscustomobject]@{ sort = $sort; query = $item.q; kind = $item.kind
                                  config = $c.label; precision = $m.precision
                                  relevant = $m.relevant; shown = $m.shown; total = $m.total }
    }
    Write-Host $line
  }
  Write-Host ""
}

Write-Host "--- mean precision@$Top ---------------------------------------------"
Write-Host ("{0,-14} {1,-10} {2}" -f 'sort', 'kind', (($configs | ForEach-Object { "{0,-13}" -f $_.label }) -join '')) -ForegroundColor DarkGray
foreach ($sort in @('relevance', 'date')) {
  foreach ($kind in @('lookup', 'concept')) {
    $line = "{0,-14} {1,-10}" -f $sort, $kind
    foreach ($c in $configs) {
      $set = $rows | Where-Object { $_.sort -eq $sort -and $_.kind -eq $kind -and $_.config -eq $c.label }
      $mean = if ($set) { [math]::Round(($set | Measure-Object precision -Average).Average, 3) } else { 0 }
      $line += "{0,-13}" -f $mean
    }
    Write-Host $line
  }
}
Write-Host ""

if ($SaveAs) {
  [pscustomobject]@{
    capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
    backfillPercent = $pct
    backfillProcessed = $status.itemsProcessed
    documentCount = $docs
    top = $Top
    rows = $rows
  } | ConvertTo-Json -Depth 8 | Set-Content $SaveAs -Encoding utf8
  Write-Host "saved: $SaveAs"
}

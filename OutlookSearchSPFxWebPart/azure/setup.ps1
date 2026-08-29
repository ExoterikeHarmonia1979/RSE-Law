<#
.SYNOPSIS
  Creates a dedicated resource group and a Basic-tier Azure AI Search service,
  then provisions the data source, index, and indexer for the .eml archive.

.NOTES
  The "50 MB limit" you hit is NOT a resource-group limit — resource groups
  have no storage quota. It is the storage cap of the FREE tier of the
  Azure AI Search *service* (matterssearch). Tiers:

    free   :  50 MB,  3 indexes  ($0)
    basic  :  15 GB/partition, 15 indexes  (~$75/mo)   <- created below
    standard S1 : 160 GB/partition ...

  Search service names are global and cannot be reused across tiers, so this
  creates a NEW service; you re-point the web part at it when done.

  Run:  pwsh ./setup.ps1
  Requires: Azure CLI (az) logged in to the right tenant.
#>

param(
  [string]$SubscriptionId   = '66268ff4-4804-4950-bfba-07b41a8660ec',
  [string]$Location         = 'eastus',
  [string]$ResourceGroup    = 'rg-rse-search-eus',
  [string]$SearchService    = 'rse-matterssearch',   # must be globally unique, lowercase
  [string]$Sku              = 'basic',
  [string]$StorageAccount   = 'samatters',
  [string]$StorageAccountRg = 'DefaultResourceGroup-EUS',  # RG that holds samatters
  [string]$FunctionApp      = 'RegExAzFunc',               # hosts EmlAttachmentNamesSkill
  [string]$FunctionAppRg    = 'regexazfunc2',
  [string]$ApiVersion       = '2024-07-01'
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubscriptionId

# 1. New resource group dedicated to search
az group create --name $ResourceGroup --location $Location --output table

<#
2. Basic-tier search service (15 GB per partition vs 50 MB on free)

`az search service create` is create-OR-UPDATE: run against an existing service it overwrites
every property with what is passed, and resets what is not passed. The live service carries
settings this script never mentions - a SystemAssigned managed identity, semanticSearch=free,
authOptions=aadOrApiKey - and that identity is what the embedding skill and the index
vectorizer authenticate to Azure OpenAI with. The web part vectorises at query time, so losing
it breaks search for users immediately, and recreating it mints a NEW principalId that no
longer holds the 'Cognitive Services OpenAI User' role.

So this step is skipped when the service already exists. Provisioning a new one still works.
#>
$exists = az search service show --name $SearchService --resource-group $ResourceGroup --query name -o tsv 2>$null
if ($exists) {
  Write-Host "Search service '$SearchService' already exists - leaving its configuration alone."
  Write-Host "  (identity, semantic search and auth options are NOT re-asserted by this script)"
} else {
  az search service create `
    --name $SearchService `
    --resource-group $ResourceGroup `
    --location $Location `
    --sku $Sku `
    --partition-count 1 `
    --replica-count 1 `
    --identity-type SystemAssigned `
    --output table

  Write-Host ''
  Write-Host 'NOTE: a new service has a new managed identity. Grant it access to Azure OpenAI:'
  Write-Host "  az role assignment create --assignee <principalId> --role 'Cognitive Services OpenAI User' \"
  Write-Host "    --scope <resourceId of the rse-matters-openai account>"
  Write-Host ''
}

# 3. Keys (kept in variables; never printed)
$adminKey = az search admin-key show --service-name $SearchService --resource-group $ResourceGroup --query primaryKey -o tsv
$queryKey = az search query-key list  --service-name $SearchService --resource-group $ResourceGroup --query "[0].key" -o tsv

# 4. Connection string for the existing blob storage account
$storageConn = az storage account show-connection-string `
  --name $StorageAccount --resource-group $StorageAccountRg --query connectionString -o tsv

$headers = @{ 'api-key' = $adminKey; 'Content-Type' = 'application/json' }
$base = "https://$SearchService.search.windows.net"

# 5. Data source -> existing 'matters' container
$ds = (Get-Content "$PSScriptRoot/datasource.json" -Raw).Replace('__STORAGE_CONNECTION_STRING__', $storageConn)
Invoke-RestMethod -Method Put -Uri "$base/datasources/matters-blob-ds?api-version=$ApiVersion" -Headers $headers -Body $ds | Out-Null
Write-Host 'Data source created.'

# 6. Index (email metadata fields + suggester + CORS for the SharePoint origin)
$idx = Get-Content "$PSScriptRoot/index.json" -Raw
Invoke-RestMethod -Method Put -Uri "$base/indexes/matters-eml-index?api-version=$ApiVersion" -Headers $headers -Body $idx | Out-Null
Write-Host 'Index created.'

<#
7. Skillset (attachment names, sent date, embeddings)

This step was missing. indexer.json names skillsetName 'matters-eml-skillset', so against a
fresh service the indexer PUT below failed on a skillset that nothing had created - the script
could never actually provision from scratch, only update a service someone had built by hand.

skillset.json carries a __FUNCTION_KEY__ placeholder for EmlAttachmentNamesSkill. Nothing
substituted it either, despite HybridVectorSearch.md claiming it happened "at provisioning".
#>
$funcKey = $env:EML_SKILL_FUNCTION_KEY
if (-not $funcKey) {
  $funcKey = az functionapp keys list -g $FunctionAppRg -n $FunctionApp --query 'functionKeys.default' -o tsv 2>$null
}
if (-not $funcKey) {
  throw "Could not resolve the function key for EmlAttachmentNamesSkill. Set EML_SKILL_FUNCTION_KEY or grant access to $FunctionApp in $FunctionAppRg."
}
$skill = (Get-Content "$PSScriptRoot/skillset.json" -Raw).Replace('__FUNCTION_KEY__', $funcKey)
Invoke-RestMethod -Method Put -Uri "$base/skillsets/matters-eml-skillset?api-version=$ApiVersion" -Headers $headers -Body $skill | Out-Null
Write-Host 'Skillset created.'

# 8. Indexer (cracks .eml/.msg and attachment documents, extracts body + text into content)
$ixr = Get-Content "$PSScriptRoot/indexer.json" -Raw
Invoke-RestMethod -Method Put -Uri "$base/indexers/matters-eml-indexer?api-version=$ApiVersion" -Headers $headers -Body $ixr | Out-Null
Write-Host 'Indexer created and first run started.'

Write-Host ''
Write-Host "Done. Web part settings:"
Write-Host "  Search service URL : $base"
Write-Host "  Index name         : matters-eml-index"
Write-Host "  Suggester name     : sg"
Write-Host "  Query key          : run 'az search query-key list --service-name $SearchService --resource-group $ResourceGroup' to view"
Write-Host ''
Write-Host "Monitor the first crawl:  az rest or portal > $SearchService > Indexers > matters-eml-indexer"
Write-Host "When satisfied, delete the old free service to avoid confusion:"
Write-Host "  az search service delete --name matterssearch --resource-group DefaultResourceGroup-EUS"

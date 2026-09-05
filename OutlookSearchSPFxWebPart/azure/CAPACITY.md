# Search service capacity

`rse-matterssearch` is **Basic** in `rg-rse-search-eus`. Basic gives 15 GB of storage and
5 GB of vector index **per partition**, and supports up to **3 partitions**.

As of 2026-09-03 it runs **2 partitions**: 30 GB storage, 10 GB vector.

## What ran out, and how it presented

Partway through the archive ingest the indexer began failing every document:

```
transientFailure   3,454 processed   3,454 failed
"Could not 'MergeOrUpload' document to the search index"
"Storage quota has been exceeded for this service."
```

Storage was at **15.01 GB of 15.00 GB**. The index was full, so nothing more could be
written. Adding a second partition took usage to 52% and the failure rate fell to
essentially zero on the next run.

```powershell
# az has no first-class command for this; PATCH the resource
$body = @{ properties = @{ partitionCount = 2 } } | ConvertTo-Json
Invoke-WebRequest -Method Patch -Headers $h -Body $body `
  -Uri ".../searchServices/rse-matterssearch?api-version=2023-11-01"
```

Provisioning takes several minutes and the service stays queryable throughout.

## Two things that mislead

**The failure ramps rather than starting.** Before it hit 100%, runs showed 345 failed,
then 807, then 1,682 - which looks like a flaky dependency, not a wall being approached.
Check `servicestats` before assuming a component is at fault:

```powershell
Invoke-RestMethod -Uri "https://rse-matterssearch.search.windows.net/servicestats?api-version=2024-07-01" `
  -Headers @{ 'api-key' = $adminKey }
```

**A separate, real skill failure was happening at the same time** and is easy to conflate
with this. Those errors read `Could not execute skill because the Web Api request failed`,
with `SocketException / Broken pipe` in the function's App Insights - Azure AI Search
timing out on `EmlAttachmentNamesSkill` and closing the connection. That was fixed
separately by streaming the request body instead of buffering it, and by dropping the
skill's `batchSize` to 1 and `degreeOfParallelism` to 3. It accounted for a few hundred
failures per run; the quota accounted for all of them.

## Sizing

At 275,517 of 425,840 archived messages ingested, the index held ~570,000 documents in
15 GB - documents outnumber messages because attachments are indexed in their own right.
Extrapolating to the full ingest gives roughly 19-20 GB of storage and 3.5 GB of vector,
which fits comfortably in the 30 GB now provisioned. A third partition is available if
that estimate proves low.

## Changing tier

`PATCH` on `sku` is rejected outright - *"Updating Sku of an existing search service is not
allowed"* - on api-version 2023-11-01. Microsoft has since added Basic <-> Standard tier
changes, but adding a partition solved this at lower cost, so that route was not needed.

## Failed documents are not retried

A blob indexer advances its high-water mark past a document that failed, so the roughly
700 documents lost to the skill timeouts, and everything that failed while the quota was
full, will not come back on the next run. They need `POST /indexers/matters-eml-indexer/reset`
followed by a run, which reprocesses the whole corpus. Worth doing once, after the ingest
is complete, rather than repeatedly during it.

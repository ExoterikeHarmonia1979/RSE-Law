# Prompt: add hybrid vector search to the existing Azure AI Search index

Paste into a fresh Claude Code session opened at `C:\Development\REPO\RSE-Law`.

Work **one phase at a time**. Each phase ends in a **GATE**: stop, report, wait.

---

## Objective

Give `matters-eml-index` **hybrid search** — keyword plus vector, fused by Reciprocal Rank
Fusion — using **integrated vectorization**, so Azure AI Search generates the document
embeddings during indexing and embeds the user's query at search time.

Nothing moves off Azure AI Search. The only new running cost is Azure OpenAI embedding tokens.

### Why not PostgreSQL + pgvector — decided 2026-08-15, do not re-litigate

The original brief was to replace AI Search with Postgres + pgvector because AI Search "is too
expensive". Costed with real numbers from the Azure Retail Prices API (eastus, USD):

| | AI Search Basic | Postgres B1ms | Postgres B2s |
|---|---|---|---|
| Compute / month | $73.73 | $12.41 | $49.64 |
| Storage (32 GiB min) | included | $3.68 | $3.68 |
| **Total** | **$73.73** | **~$16.19** | **~$53.42** |

The migration saves **$20–58/month**. Against that it would have required rebuilding ingestion,
document cracking, query translation, highlighting and suggestions, and **would have lost
attachment-content search** unless Document Intelligence were added — reintroducing the cost the
move was meant to avoid.

The deciding fact: **Azure AI Search already does vector and hybrid search on Basic at no extra
charge.** Only the semantic ranker is a paid add-on. The service is already the cheapest paid
tier and is 5% utilised (730 MB of 15 GB, 1 index of 15), so there is nothing to downsize into.
Migrating would have paid $20–58/month for a large rebuild and a capability regression.

## Decisions already made

| # | Decision |
|---|---|
| Model | **`text-embedding-3-small`, 1536 dimensions.** $0.022/1M tokens against `3-large` at $0.143/1M — 6.5× — for no benefit at this corpus size |
| Scope | **Metadata + body text.** Already satisfied: `content` is produced by document cracking and includes body *and* attachment text |
| Unsorted mail | **Indexed.** Already true — the indexer covers the whole container, so the ~6,000 `UnsortedMatterCommunication` blobs are in the 41,137 |

## What exists today — verified, do not re-derive

| Component | Detail |
|---|---|
| Service | `rse-matterssearch`, rg `rg-rse-search-eus`, **Basic**, 1 replica / 1 partition, East US |
| Index | `matters-eml-index` — 11 fields, suggester `sg`, CORS for `https://reiszsidermaneisenberg.sharepoint.com` |
| Volume | **41,137 documents, 730 MB** of a 15 GB quota |
| Indexer | `matters-eml-indexer` — PT1H schedule, `.eml,.msg`, `dataToExtract: contentAndMetadata` |
| Skillset | `matters-eml-skillset` → custom `EmlAttachmentNamesSkill` (RegExAzFunc) → `attachmentNames`, `sentDate` |
| Definitions | `OutlookSearchSPFxWebPart/azure/{index,indexer,datasource,skillset}.json`, provisioned by `azure/setup.ps1` |
| Webpart | `outlook-search-spfx/src/webparts/outlookSearch/services/AzureSearchService.ts` |
| Azure OpenAI | **None exists in the subscription.** Phase 1 creates it |

---

## Phase 1 — Azure OpenAI resource and embedding deployment

1. Create an Azure OpenAI (Foundry) resource in a region where `text-embedding-3-small` is
   available and which is sensible next to East US.
2. Deploy `text-embedding-3-small`. Check the deployment's tokens-per-minute quota against a
   41,137-document backfill and raise it if it would throttle the reindex.
3. **Auth by managed identity, not a key.** Enable the search service's system-assigned identity
   and grant it **Cognitive Services OpenAI User** on the OpenAI resource.

`skillset.json` currently carries a `__FUNCTION_KEY__` placeholder substituted at provisioning
time. **Do not extend that pattern to Azure OpenAI** — the skill and the vectorizer both support
managed identity, and GitHub push protection is active on this repo and has already blocked one
commit for an embedded secret.

**GATE 1** — report the resource, deployment name, quota, and that the role assignment exists.

---

## Phase 2 — Index schema

Add to `azure/index.json`:

- a vector field, e.g. `content_vector`, `Collection(Edm.Single)`, `dimensions: 1536`,
  `searchable: true`, with a `vectorSearchProfile`;
- a `vectorSearch` block with an **HNSW** algorithm config and a **vectorizer** of kind
  `azureOpenAI` pointing at the Phase 1 deployment, using managed identity.

The vectorizer is what lets the webpart send `kind: "text"` and have the service embed the query
server-side. Without it the client would have to call Azure OpenAI itself — which would put an
OpenAI credential in the browser. Do not do that.

**Verify before building on it:** confirm a vector field and `vectorSearch` config can be added
to the *existing* index in place. Adding fields is additive and allowed; if the `vectorSearch`
block cannot be added to a live index, the fallback is to build a second index and swap the
webpart's `indexName` property — which is also the cleaner rollback. Establish which applies
before touching anything.

Also check the **vector index size quota** on Basic — it is a separate limit from the 15 GB
storage quota. 41,137 × 1536 × 4 bytes ≈ **253 MB** of raw vectors, which should be
comfortable, but confirm it from `/servicestats` rather than assuming.

**GATE 2** — report the schema change and which path (in-place vs new index) is being taken.

---

## Phase 3 — Embedding skill and backfill

Add `#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill` to `azure/skillset.json`, with
`outputFieldMappings` in `azure/indexer.json` writing the vector to `content_vector`.

**One decision to make deliberately.** `text-embedding-3-small` accepts at most 8,191 tokens, and
`content` for a long email with attachments will exceed that.

| Option | Consequence |
|---|---|
| **Truncate — embed the first chunk only** | One vector per document. The index stays one-document-per-blob, so the webpart and `getContent` are unchanged. Long documents lose vector recall past the cut |
| Chunk — a vector per chunk | Better recall on long documents, but the index becomes one-document-per-chunk. That changes result identity, paging, counts and dedupe, and the UI assumes one row per email |

Recommendation: **truncate**. Use a `SplitSkill` in `pages` mode ahead of the embedding skill and
embed the first chunk. Keyword search still covers the full `content`, so the long tail is not
lost — only its vector contribution is. Revisit only if recall proves poor in Phase 5.

Then backfill: **reset and run the indexer** (`POST /indexers/matters-eml-indexer/reset`, then
`/run`). A plain run only picks up changed blobs, so without the reset the 41,137 existing
documents keep null vectors. Note that a reset re-invokes `EmlAttachmentNamesSkill` for every
document too — watch `maxFailedItems` (currently 100) and the function app.

Cost: roughly **$0.90** in embedding tokens for the whole corpus.

**GATE 3** — report indexer status, documents processed, failures, vector index size, elapsed
time and actual cost.

---

## Phase 4 — Hybrid query in the webpart

In `AzureSearchService.search()`, add a vector query alongside the existing keyword search — both
in one request is what makes it hybrid; AI Search fuses them with RRF automatically:

```jsonc
{
  "search": "<existing Lucene from OutlookQueryParser>",
  "queryType": "full",
  "searchMode": "all",
  "vectorQueries": [
    { "kind": "text", "text": "<raw user text>", "fields": "content_vector", "k": 50 }
  ]
}
```

Send the **raw** user text to `vectorQueries`, not the Lucene-escaped string — escaping is for the
keyword parser and would corrupt the sentence the embedding is meant to represent. Keep
`parseOutlookQuery`'s `filter` applied; filters work with vector queries.

Things that must keep working — check each against the current file:

- **`orderby: 'sent_date desc'`** for the date-sort toggle. Verify it is compatible with
  `vectorQueries`; relevance-ranked and date-ordered results interact awkwardly. If it is not,
  drop the vector query when the user sorts by date, and say so in the UI or the code comment.
- **Highlighting** (`highlight: 'content,metadata_subject'` with the `\uE000`/`\uE001` sentinels)
  — highlights come from the keyword half; confirm they still return under hybrid.
- **`@odata.count`** for paging.
- **`getContent`** and the `suggest` path are untouched.
- `EmlPreviewFunc` and the reading pane are untouched.

**GATE 4** — side-by-side results for a set of real queries, keyword-only versus hybrid.

---

## Phase 5 — Tune and verify

Compare against today's behaviour on queries that exercise the difference: conceptual phrasing
that shares no keywords with the text, misspellings, and the prefix filters (`from:`, `subject:`,
`received:`, `hasattachment:`). Tune `k` and, if recall is poor, HNSW `efSearch` before
reconsidering the truncation decision.

Report honestly where hybrid is *worse* — vector recall can pull in loosely-related results and
push out an exact match someone expected. That is the main risk of this change, and it is a
tuning problem, not a reason to abandon it.

**GATE 5** — recommendation on defaults.

---

## Constraints

- `azure/*.json` are the source of truth; provision through `azure/setup.ps1`, not the portal.
- **RegExAzFunc zip deploy replaces every function in the app** — the repo project is the source
  of truth. Only relevant if `EmlAttachmentNamesSkill` needs changing; it probably does not.
- `az` is a per-user ZIP install: `& "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"`. It mangles
  `$top`/`$filter`/`$skiptoken` in ARM URLs — use `Invoke-RestMethod` with a bearer token.
- **`az` also silently discards characters from blob names** ("Unable to encode the output with
  cp1252 encoding") — 122 of 6,053 measured, 2%. List over REST whenever names matter.
- No secrets in committed JSON. Managed identity throughout.
- The webpart's `apiKey` property is an AI Search **query** key and stays as-is.

## Rollback

| Phase | Rollback |
|---|---|
| 1–2 | Nothing user-facing. Delete the field / the OpenAI deployment |
| 3 | Vectors are additive; keyword search is unaffected throughout |
| 4 | Remove `vectorQueries` from the request — one property |
| 5 | Tuning only |

If Phase 2 takes the second-index path, rollback at any point is flipping the webpart's
`indexName` back.

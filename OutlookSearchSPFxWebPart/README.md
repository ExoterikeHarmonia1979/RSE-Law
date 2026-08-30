# Outlook-Style Email Archive Search (SPFx)

SharePoint Framework web part that reproduces the Outlook three-pane experience
(see `IMG/Outlook.PNG`) over an archive of `.eml` files stored in the
`samatters/matters` blob container and indexed by Azure AI Search.

```
┌──────────────────────────────────────────────────────────┐
│  ▄ blue top bar          [ 🔍 Search           ]         │  SearchBar.tsx
├───────────────────────┬──────────────────────────────────┤
│ Results (1,234)  By Date ⌄ │  FW: 23-2209121- Please Review │
│ ── Today ──────────── │  (SD) Scott Dallas               │
│ (SD) Scott Dallas   📎 │  To: Daniel Eisenberg            │
│  FW: 23-2209121-…     │  Cc: RSE Matters                 │
│  snippet with <mark>… │  📎 Outlook-q3zocl…              │
│ ── Yesterday ───────── │                                  │
│ (MG) Marco Galindez   │  Hi Dan, I'm holding off on…     │
│  …                    │  (email body + attachment text)  │
└───────────────────────┴──────────────────────────────────┘
  EmailList.tsx              ReadingPane.tsx
```

## Solution layout

| Path | Purpose |
|---|---|
| `outlook-search-spfx/` | SPFx 1.23 solution (React 17 + Fluent UI 8) |
| `…/services/AzureSearchService.ts` | All Azure AI Search REST calls via SPFx `HttpClient` |
| `…/services/OutlookQueryParser.ts` | Outlook search-syntax → Lucene + OData `$filter` |
| `…/components/SearchBar.tsx` | Outlook search bar: type-ahead, recents, keyboard nav |
| `…/components/EmailList.tsx` | Left pane: date-grouped result list |
| `…/components/ReadingPane.tsx` | Right pane: metadata header + extracted text preview |
| `azure/` | Scripts + JSON to provision the new search service |

## Search bar behavior (mirrors Outlook)

- Type-ahead suggestions after 3 characters (250 ms debounce) from the index
  suggester, mixed with your recent searches (stored in `localStorage`).
- `↑`/`↓` navigate suggestions, `Enter` runs the search, `Esc` closes/clears.
- Outlook query prefixes are translated server-side:
  `from:"Scott Dallas"`, `to:eisenberg`, `cc:matters`, `subject:review`,
  `received:2026-08-07`, `before:2026-08-01`, `after:2026-07-01`,
  `hasattachment:yes`. Plain words must all match (`searchMode=all`).
- Empty search shows the newest messages, like an Outlook folder view.

## Build / run

```powershell
cd outlook-search-spfx
npm install
npm run start    # hosted workbench: https://<tenant>.sharepoint.com/_layouts/15/workbench.aspx
npm run build    # produces sharepoint/solution/outlook-search-spfx.sppkg
```

Upload the `.sppkg` to the tenant App Catalog, add the app to the site, then in
the web part property pane set:

| Property | Value |
|---|---|
| Search service URL | `https://rse-matterssearch.search.windows.net` |
| Index name | `matters-eml-index` |
| Query API key | a **query** key (never an admin key) |
| API version | `2024-07-01` |
| Suggester name | `sg` |

> The query key is stored in the web part properties, i.e. visible to any user
> who can view the page source. Query keys can only read the index — that is the
> intended pattern for client-side search — but if the archive itself is
> sensitive, front the service with an Azure Function / API Management instead
> and swap the URL in the property pane.

## Fixing the 50 MB limit

The 50 MB cap is **not** on the resource group (`DefaultResourceGroup-EUS`) —
resource groups have no storage quota. It is the storage cap of the **Free tier
of the Azure AI Search service** (`matterssearch`). A search service cannot be
upgraded in place from Free, so you create a new service and re-point:

```powershell
cd azure
pwsh ./setup.ps1     # az login first, correct tenant
```

The script:

1. Creates resource group `rg-rse-search-eus` in East US.
2. Creates **Basic** tier service `rse-matterssearch` — 15 GB per partition
   (~$75/month). Use `-Sku standard` (S1, 160 GB) if the archive will outgrow that.
3. Creates the data source pointing at the existing `samatters/matters` container.
4. Creates `matters-eml-index` with the email metadata fields, a suggester (`sg`),
   and CORS allowing `https://reiszsidermaneisenberg.sharepoint.com` (required —
   the browser calls the search endpoint directly).
5. Creates an hourly indexer that cracks `.eml`/`.msg` files:
   `dataToExtract: contentAndMetadata` extracts the body **and attachment text**
   into `content`, plus `metadata_message_from/to/cc`, `metadata_subject`,
   `metadata_creation_date`.

Afterwards update `.env` and the web part properties with the new service name,
and once the first crawl finishes you can delete the old free service.

`.env` is not in the repo — copy `.env.example` to `.env` and fill it in. The
template holds only resource names and URLs (no keys), but `.env` is where a key
would eventually be added, so it is ignored rather than tracked.

Note: `attachment_names` exists in the schema so `hasattachment:` queries work,
but the built-in indexer does not populate per-attachment names; filling it
requires a small skillset (or the RegExAzFunc pattern) later.

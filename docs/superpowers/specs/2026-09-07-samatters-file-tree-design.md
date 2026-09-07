# A file tree over the matters container, in the archive search web part

Design record for adding a blob-explorer pane to `OutlookSearchSPFxWebPart`: the full
`samatters/matters` container as a lazy tree, `.eml`/`.msg` opening in the existing preview
pane, attachments downloading on click, a per-row download control, and a folder-level
download that zips everything beneath it, attachments included.

## What the container actually looks like

Measured from `infra/logicapps/tools/archive-blobs.txt` (listing of 2026-09-05) and
`az storage container list`:

| | |
|---|---|
| Containers in `samatters` | **1** — `matters`. "The whole storage account" is this container. |
| Listing entries | 965,180 |
| `.msg` blobs | 362,523 |
| `.eml` blobs | 334,612 |
| Attachment blobs (`*/Attachments/*`) | 261,858 |
| Top-level matter folders | 1,519 |
| Largest folder | `UnsortedMatterCommunication` — **201,356** entries |
| Next largest | `95A.002` — 11,691; then `120.057` — 8,388 |

Two facts drive most of this design. The tree cannot be materialised — no client holds
965,180 nodes. And one folder is two orders of magnitude larger than the rest, so every
operation has to be correct on `UnsortedMatterCommunication` before it is convenient
anywhere else.

Layout follows `INGEST-BLOB-NAMING.md`:

```
<matter>/Emails/<subject capped 150> [<token>].eml        # or .msg from the ingest
<matter>/Emails/Attachments/<token>/<attachment capped 180>
```

## Decisions

### Live listing, one level per request

Expansion calls `GetBlobsByHierarchyAsync` with `delimiter: "/"` and the node's prefix.
Nothing is cached server-side, so the tree is always exactly what is in the container.

Rejected: **a precomputed tree manifest** — instant expands and folder counts up front, but
it is a scheduled walk to run and monitor, and `archive-blobs.txt` shows what that costs
(105 MB, stale the moment the next Logic App run fires). It can be added later as a cache
in front of this contract without changing it.

Rejected: **driving the tree from the Azure AI Search index** — free counts via facets, but
the index holds cracked documents, not blobs. `purge-index-orphans.ps1` exists because it
keeps rows for blobs that are gone, and "Make the indexer revisit blobs it has already
skipped" exists because it misses others. A complete breakdown of the container is the one
thing the index cannot promise.

### The download cap is enforced by an early-exit walk

A folder download is refused above **2,000 files or 2 GB**. The pre-flight walk stops the
moment either limit is crossed, so checking `UnsortedMatterCommunication` costs the same as
checking any other folder: it enumerates 2,001 entries, not 201,356.

Consequence, and it must reach the UI wording: past the cap the true count is unknown. The
dialog says **"more than 2,000 files"**. It never states a count the walk did not finish.

### Zipping streams; it does not buffer

`ZipArchive` in `Create` mode over `Response.BodyWriter.AsStream()`, each blob copied in
from `OpenReadAsync`. Memory is flat regardless of folder size. `CompressionLevel.Fastest`:
mail compresses, PDFs do not, and CPU is the scarce thing on a Consumption plan.

An async job queue was rejected. It handles any folder size, but it costs a queue, a worker,
job state, expiry and a polling UI — and with the cap in place, every folder a person
actually wants is already reachable inline.

### A new function file, sharing extracted plumbing

`EmlPreviewFunc.cs` is ~500 lines already serving preview, `.eml` download and attachment
extraction. Listing and zipping go in `MattersBrowseFunc.cs`. The plumbing both need —
container resolution, `LoadBlobBytes`, `ContentDisposition`, `InferContentType`,
`IsMailBlob` — moves to an internal `MattersBlobs` helper. This is the only refactor in
scope, and it is forced by the second caller.

### Same visibility posture as search

Anyone who can view the web part can browse the whole container, exactly as they can
already search all of it. The storage credential stays in the function; the page holds only
a function key. Per-matter authorization would need a matter-to-user mapping, real caller
identity instead of a shared key, and Entra token validation — a larger project, and out of
scope here.

## The contract

`MattersBrowseFunc`, `AuthorizationLevel.Function`, matching the deployed pattern.

```
GET ?op=list&prefix=<p>&cursor=<token>
 -> { prefix, folders: [{ name, path }],
      files:   [{ name, path, sizeBytes, lastModified, kind }],
      cursor?: string }
    kind: 'eml' | 'msg' | 'attachment' | 'other'
      'attachment' when the blob name contains '/Attachments/', else by extension;
      the kind drives the row icon and whether a click previews or downloads
    500 entries per page; 1,000 at the root

GET ?op=probe&prefix=<p>
 -> { files, bytes, withinLimit }        early-exit walk; counts are lower bounds when
                                         withinLimit is false

GET ?op=zip&prefix=<p>
 -> 200 application/zip, streamed, Content-Disposition attachment
 -> 413 { files, bytes, fileLimit, byteLimit } when over the cap
```

`path` is the full blob URL (`https://samatters.blob.core.windows.net/matters/<name>`).
`LoadBlobBytes` already accepts that form, so tree rows reach the **existing** endpoints
unchanged: `.eml`/`.msg` rows POST to `EmlPreviewFunc` for the preview pane, and the row
download button is the existing `?path=` GET — which already infers a content type and
attachment disposition for loose attachment blobs.

`probe` is a separate call because a folder download is a browser navigation, and a
navigation answered with 413 shows the user nothing at all. The UI probes, shows the refusal
with real numbers, and only navigates when the answer is yes.

Zip entry paths are relative to the requested prefix, so a zip of `120.057/` opens as
`Emails/….eml` beside `Emails/Attachments/<token>/….pdf` — the structure is what carries
"attachments included".

A blob can disappear between listing and reading; the soft-delete detection policy in
`azure/datasource.json` exists because that happens. Once bytes are on the wire the status
is already sent, so the zip skips the missing blob and ends with a `_download-errors.txt`
entry naming what was skipped. A short zip with a manifest beats a silently short one.

## The web part

New property `browseFuncUrl` (including `?code=`), alongside `emlPreviewUrl`. Unset or
rejected renders a configuration notice in the tree pane, mirroring how an empty
`emlPreviewUrl` already degrades to plain text.

### Files

| Path | Purpose |
|---|---|
| `components/FileTree.tsx` | The pane: filter box, virtualized rows, expansion state |
| `components/FileTreeRow.tsx` | One row: chevron, kind icon, name, size, download control |
| `services/BlobBrowseService.ts` | `list` / `probe` / zip-URL construction |
| `models/ITreeNode.ts` | Node shape and the visible-node flattening |
| `services/downloadUrls.ts` | Extended with the browse URLs |
| `components/OutlookSearch.tsx` | Three-pane grid; owns `selectedStoragePath` |
| `components/OutlookSearch.module.scss` | Grid change and the collapse breakpoint |

### Layout

Three columns — tree 280px, result list 360px, preview taking the rest. Below ~1100px the
tree collapses to a folder-icon toggle in the top bar and overlays when opened; three panes
on a standard SharePoint canvas leaves the preview unreadable otherwise. The tree pane
resizes by drag, persisted in `localStorage` beside the existing search history.

### Tree behaviour

Rows render through Fluent's virtualized `List` over a flat array of visible nodes derived
from expansion state — the pattern the result list already uses. Virtualization is a
requirement, not a refinement: 1,519 roots, and one folder with 201,356 children.

Expanding fires `op=list`, 500 per page. Beyond that the tree appends an explicit
**"Load more — 500 shown so far"** row rather than infinite scroll, which in a folder that
size never ends and gives no sense of position. The count is what has been fetched, never a
total: a live listing does not know how many children a prefix has, and `probe` only counts
as far as the cap. The row must not imply otherwise. The root level fetches 1,000 per page,
so all 1,519 matters arrive in two calls and are cached for the session.

The filter box narrows those cached root folders by substring — typing `120.` reaches the
matter without scrolling 1,519 rows. It filters roots only; finding a *message* is what the
search pane is for.

Click behaviour:

| Row | Click | Download control |
|---|---|---|
| Folder | Expand / collapse | Probe, then zip that folder |
| `.eml` / `.msg` | Preview in the reading pane | Download the message |
| Attachment | Download it | Download it |

Both panes write to one `selectedStoragePath` in `OutlookSearch.tsx`; last click wins, and
the tree highlights a row only if it is already visible. Clicking a search result
deliberately does not reveal it in the tree: that means expanding every ancestor and paging
to find the row, possibly inside the 201k folder. A "Show in tree" button in the preview
header would be the honest way to offer it, and is out of scope here.

## Fixing `.msg` preview

`.msg` outnumbers `.eml` in the container (362,523 to 334,612) because the ingested quarters
landed as `.msg`. `EmlPreviewFunc.IsMailBlob()` accepts `.msg`, but `LoadMessage()` hands the
bytes to `MimeMessage.Load`, and MimeKit cannot parse a compound file. `MsgReader 6.1.0` is
already a `RegExAzFunc.csproj` dependency but is never referenced from `EmlPreviewFunc.cs`.
So a `.msg` preview returns the guarded parse error today — live in search results now, and
unavoidable once a tree invites people to click these files directly.

The fix lands in `EmlPreviewFunc`, which owns the sanitizer and `cid:` inlining:

- Detect by sniffing the compound-file signature `D0 CF 11 E0 A1 B1 1A E1`, not by
  extension. The ingest derived blob names from subjects; an extension is not evidence.
- Parse with MsgReader `Storage.Message` and project into the same `IEmailPreview` JSON
  already consumed by the web part — subject, from, to[], cc[], date, sanitized `htmlBody`,
  `textBody`, `attachments[{name,sizeBytes}]`. No TypeScript change.
- Give `ServeAttachment` the same treatment, or the preview lists attachments from a `.msg`
  that then fail to open.

## Testing

TypeScript, through the existing `heft test` (jest): visible-node flattening from expansion
state, prefix and path helpers, the root filter, and the URL builders. All pure.

C#: **the repo has no test project.** This adds a small xunit one covering the pure logic —
zip entry naming, cap arithmetic and early exit, compound-file sniffing, path parsing — with
blob access behind `MattersBlobs` so it can be faked.

Streaming behaviour and real `.msg` parsing are verified against the live container through
the local Functions host. The implementation plan records what was checked that way; they
are not claimed as unit-tested.

## Out of scope

- Per-matter authorization (see the visibility decision above).
- "Show in tree" from a search result.
- Folder counts and sizes shown before expansion — that is the manifest approach, addable
  later behind the same contract.
- Renaming, moving, deleting or uploading blobs. This pane reads.

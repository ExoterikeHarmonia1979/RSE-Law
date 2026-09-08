# Verifying the file tree in the workbench

The one thing this feature has never been run against: a deployed `MattersBrowseFunc`
behind a live web part. Everything below that seam is verified — the three operations
ran against the real `samatters/matters` container, and the client is unit-tested — but
nobody has yet clicked a folder in a browser. This is that check, in the order that
finds problems soonest.

Run it after deploying the function and adding the web part to a page.

### 0. Prerequisites — set up the two URL properties

1. Deploy `MattersBrowseFunc` (it ships in the same function app as `EmlPreviewFunc` — the
   existing zip-deploy of `RegExAzFunc` already carries it; no new app settings are needed beyond
   `MATTERS_STORAGE_CONNECTION` and `MATTERS_CONTAINER_URL`, which `EmlPreviewFunc` already
   requires).
2. Get the function's key: Azure Portal → the function app → **Functions** → `MattersBrowseFunc` →
   **Function Keys** → copy `default` (or run
   `az functionapp function keys list --function-name MattersBrowseFunc --name <app> --resource-group <rg>`).
3. Run `npm run start` from `OutlookSearchSPFxWebPart/outlook-search-spfx` and open the hosted
   workbench (`https://<tenant>.sharepoint.com/_layouts/15/workbench.aspx`), add the web part.
4. In the property pane, under **Azure AI Search connection**, set:
   - **EML preview service URL** → the deployed `EmlPreviewFunc` URL with its `?code=` key
     (needed for behaviours 2-4 below; without it the tree still lists/browses, but clicking a
     message falls back to plain extracted text and downloads are disabled).
   - **File tree service URL** → the deployed `MattersBrowseFunc` URL with its `?code=` key, e.g.
     `https://<funcapp>.azurewebsites.net/api/MattersBrowseFunc?code=<key>`.
   - If this field is left empty, confirm the tree pane and its splitter do not appear at all and
     the original two-pane view still works normally — that is the fallback behaviour this task
     was responsible for preserving.

### 1. Tree lists matter folders; filter narrows them

**Do:** With the tree visible, look at the root list; type `120.` into the tree's filter box.
**Expect:** Root-level folders appear (matter numbers, `UnsortedMatterCommunication`, etc.);
typing `120.` narrows the visible root rows to only those starting with `120.`.
**If it fails:** No rows at all → check the `MattersBrowseFunc` URL/key are correct and the
function app is actually running (test the URL directly with `&op=list&prefix=` in a browser —
should return JSON, not a 401/404/500). Filter doing nothing → likely a client-side bug in
`FileTree`'s filter wiring, not this task's code (Task 7's responsibility), but check the browser
console for a JS error first since a thrown error can look like "does nothing."

### 2. Expand a matter → Emails; click an `.eml`

**Do:** Expand `120.057` (or any real matter folder), then expand `Emails`, then click an `.eml`
row.
**Expect:** The reading pane on the right shows that message's header block and body — the exact
same rendering a search-result click produces, because `handleSelectPath` builds a minimal
`IEmailItem` and delegates to the same `handleSelect` used everywhere else.
**If it fails:** Tree expands but reading pane stays empty → check `emlPreviewUrl` is set (if
empty, it falls back to `getContent`, which reads plain text from the search index by
`storagePath` — if the search index doesn't have that path indexed, this legitimately shows an
error, which is expected and not a bug in this wiring). Nothing happens on click at all → check
`onSelectMessage` is actually reaching `FileTree` (network tab should show no calls; this would
point to a prop-wiring regression in `OutlookSearch.tsx`, i.e. this task's own code).

### 3. Click a `.msg`

**Do:** Click a `.msg` file row instead of `.eml`.
**Expect:** Renders the same way `.eml` does (this is Task 2's server-side `.msg` fix reaching the
UI — the client code path is identical for both extensions).
**If it fails:** `.eml` works but `.msg` doesn't → the bug is almost certainly server-side
(`EmlPreviewFunc`'s `.msg` handling, Task 2), not in this task's wiring, since both extensions go
through the exact same `handleSelectPath` → `handleSelect` → `service.getPreview` path with no
extension-specific branching on the client.

### 4. Click an attachment row

**Do:** With a message open in the reading pane, click one of its attachment chips.
**Expect:** Downloads (or opens, depending on file type) that attachment.
**If it fails:** This exercises `ReadingPane`/`attachmentUrl` from `downloadUrls.ts`, both
pre-existing and unmodified by this task — check `emlPreviewUrl` is set and reachable.

### 5. File row vs. folder row download button

**Do:** Click the download control on a single file row in the tree; separately, click it on a
folder row (e.g. a matter folder or `Emails`).
**Expect:** File → saves that one file (via `handleDownloadPath` → `emlDownloadUrl` →
`EmlPreviewFunc`). Folder → downloads a `.zip` (via `BlobBrowseService.zipUrl` → `MattersBrowseFunc`
`op=zip`) whose contents include the `Attachments/` subtree alongside the messages.
**If it fails:** File download not firing → check `emlPreviewUrl` is set (per `handleDownloadPath`,
an empty `emlPreviewUrl` makes the file-download button a no-op by design, not a bug). Zip missing
`Attachments/` → server-side zip assembly in `MattersBrowseFunc` (Task 6), not this task's code.

### 6. `UnsortedMatterCommunication` refusal dialog

**Do:** Click the download/zip control on the `UnsortedMatterCommunication` folder (or whatever
root folder is known to exceed the cap).
**Expect:** A dialog appears promptly (not after a long hang) reading something containing
**"more than 2,000 files"** (the exact wording comes from `capMessage` in `FileTree.tsx`: `"This
folder holds more than 2,000 files or more than <size>, which is too much for a single archive.
Open a folder inside it and download that instead."`).
**If it fails:** Dialog never appears / hangs → check the probe (`op=probe`) call in the network
tab — a slow or failing probe response points at `MattersBrowseFunc`'s probe implementation
(Task 6), not the client. Dialog appears but with different wording or without "2,000" → check
`IProbeResult.fileLimit`/`byteLimit` coming back from the function match what `capMessage` expects
to format.

### 7. Narrow below 1100px

**Do:** With the tree visible and all three panes showing, shrink the browser window's width below
~1100px (or resize the workbench iframe if that's how it's embedded).
**Expect:** The tree pane and its splitter disappear entirely; only the original two-pane
list+reading view remains, and it stays usable (not squeezed to the point of being unreadable).
**If it fails:** Tree stays visible below 1100px → check the compiled CSS actually contains the
`@media (max-width: 1100px)` block from `OutlookSearch.module.scss` (a caching issue after
`npm run start` is the most likely cause — hard-refresh). Two-pane view becomes unreadable even
with the tree hidden → that's a pre-existing constraint of `LIST_WIDTH_MIN` (260) +
`READING_WIDTH_MIN` (320) = 580px minimum for those two panes alone, unrelated to this task; 1100px
was chosen with headroom above that.

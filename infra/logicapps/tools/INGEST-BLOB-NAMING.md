# Blob naming and execution plan for the archive ingest

Decision record. No ingest code exists yet. This settles two things that are expensive to
change later: the identifier ingested blobs are named by - which constrains dedup,
attachment layout and re-runnability - and where the export runs, which the measured
transfer rates decide rather than taste.

## The problem

Blobs are named today by `transform.ps1`:

```
<matter>/Emails/<subject capped 150> [<idTail>].eml
<matter>/Emails/Attachments/<idTail>/<attachment name capped 180>

idTail = last 24 chars of the Graph message id, '/'->'_', '+'->'-', '=' dropped
```

The identifier appears twice — in the `.eml` name and as the attachment folder — so any
scheme has to supply both.

**The Graph message id is store-scoped.** The same message carries a different id in the
In-Place Archive than in the primary mailbox. Reusing this rule for ingested items would
therefore write a *new* blob beside the existing one for every message the retention
policy has already moved — silent duplicates, invisible in run history. That is the same
shape as the 28,915 redundant blobs this project has already had to clean up once, and
PR #6 measured at least 9 such overlaps on matter `120.057` alone.

Naming and dedup cannot be answered separately: if the name is not a function of the
dedup key, a re-run cannot overwrite what it wrote last time.

## Decision

Derive the identifier from the dedup key.

```
key    = sha256( lower(message-id) + '|' + sent-date-utc-to-the-second )
token  = 'k' + first 22 hex chars of key

<matter>/Emails/<subject capped 150> [<token>].eml
<matter>/Emails/Attachments/<token>/<attachment name capped 180>
```

Rationale, component by component:

- **Message-ID** is the one identity that survives an item moving between stores. It is
  why the Message-ID index exists, and `parse-mapi-export.py` recovers it from **100%** of
  a 100-item sample — 74% from the transport header block, 26% from
  `PidTagTnefCorrelationKey` for internal mail that never traversed SMTP and has no headers.
- **Sent date is not decoration.** Message-ID alone is *not* unique in this corpus: 3,835
  groups of genuinely different messages share one, because Outlook reuses the header
  across separately composed mail. Two such messages were confirmed 14 minutes apart in
  different matters, sharing Message-ID *and* Thread-Index. The sent date separated every
  collision examined. It is recovered for 100% of the sample (header `Date:` where present,
  otherwise `PidTagClientSubmitTime`).
- **Hashing** gives fixed width and ASCII safety. Raw Message-IDs run 80+ characters and
  would crowd the 150-char subject stem; non-ASCII blob names have already caused 87
  spurious 404s in `az storage blob list`, so keeping generated components ASCII is a
  known-cost decision, not a preference.
- **The `k` prefix** keeps the two identifier spaces distinguishable at a glance and in
  code. Legacy tails are 22-23 chars of base64; `k…` is unambiguous. The existing
  `\[([^\]]+)\]\.eml$` parse in `build-messageid-index.ps1` keeps working unchanged.

The property this buys: **same message -> same key -> same name -> a re-run overwrites
instead of duplicating.** That idempotency is what `sweep-older-mail.ps1` and
`reconcile-missed.ps1` already rely on when they re-enqueue freely.

## Consequences accepted

**Names become opaque.** You can no longer read a Message-ID off a blob name, which is a
real loss when debugging. Mitigation: `messageid-index.tsv` already maps blob -> Message-ID,
and the ingest must append index rows as it writes rather than leaving the index to a
24-minute rebuild.

**Existing blobs are not renamed.** All 258,974 keep their Graph-id tails. Renaming would
be a mass rewrite that churns the search index for no functional gain, and the Message-ID
index already bridges the two identifier spaces. Legacy names stay legacy; the prefix is
what tells them apart.

**Subject may be missing for the stem.** Subject is *not* part of the key, so this never
affects identity or dedup — but it is the human-readable stem. It is recovered for 74% of
the sample, from the header block. The MAPI subject properties (0x0037 / 0x0E1D) are not
located by the current tag scan, so the remaining 26% must fall back to `(no subject)`,
matching what `Email_Subject_Clean` already does for blank subjects. Worth fixing for
legibility; it is not a correctness gate.

## How the export runs

**The route is eDiscovery Content Search, not the Graph `exportItems` API.** The API
measurements in the next subsection are kept because they were real and they explain why
that path was attractive - but its payload cannot be read (see "Getting .eml out of the
export"), so it is not the plan.

### Verified on the live tenant, 2026-08-31

A Content Search run as `SharePoint@rse-law.com` against `matters@rse-law.com`, scoped to
`sent>=2024-01-01 AND sent<=2025-12-31` - a window that can only be satisfied from the
In-Place Archive, since anything that old aged out of the primary mailbox months ago:

```
Status : Completed      Errors : (none)
Items  : 344,686
Size   : 164.9 GB       average item 502 KB
```

That is 81% of the archive's 425,840 items and 80% of its 205.8 GB, which is the expected
shape and confirms the search really is reading archive content.

Three things this settles that were previously open:

- **Office 365 E3 (`ENTERPRISEPACK`) is sufficient.** Microsoft's export documentation
  says "Microsoft 365 E3 or E5", which is a different SKU from the one this tenant holds.
  That ambiguity is now resolved by evidence rather than by reading.
- **The service account can sign in interactively**, which was not a given - service
  accounts are frequently MFA-bound or sign-in blocked.
- **The permissions work**: `SharePoint@rse-law.com` in the `eDiscovery Manager` role
  group, which already carried the Export role.

Two operational notes bought with real failures:

- `Connect-IPPSSession` must run in **PowerShell 7**. The 5.1 / ISE build authenticates
  through the WAM broker and dies with *"A window handle must be configured"*.
- **`-EnableSearchOnlySession` is mandatory** from module v3.9.0. Without it
  `Start-ComplianceSearch` fails at initialisation and the search still reports
  `Status=Completed, Items=0` - indistinguishable from an empty archive unless you read
  `Errors`. Never trust a zero without checking it.

### Sizing the real run

At the measured 502 KB average:

| Scope | Items | Transferred |
|---|---|---|
| File Cabinet only | 310,190 | ~148 GB |
| Everything incl. Inbox and Deleted Items | 425,840 | ~204 GB |

Purview caps a PST at 10 GB and a zip package at 40 GB, so even the smaller scope is at
least 4 zip packages and ~15 PSTs. Combined with the hard limits - export packages expire
after **14 days**, and an export running more than **7 days** is cancelled automatically -
the run has to be split into batches by date range regardless of which scope is chosen.

### What the Graph exportItems API does (measured, but not the route taken)

| | |
|---|---|
| Batch ceiling | **exactly 20 item ids**; 21 returns `ExportMailboxItemsRequestInvalid` |
| 1 worker, batch 20 | 934 items/min |
| **4 workers, batch 20** | **3,347 items/min**, 21.8 MB/s, 0 failures |
| 8 workers, batch 20 | 2,212 items/min, 8 failures — throttled, *slower* than 4 |
| Average item | ~390 KB, so ~121 GB for 310,190 File Cabinet items |

Folder enumeration is not a cost: 29 series folders in 0.4s, ~8 folders/s while walking
matters.

At 4 workers the export of the File Cabinet takes **~1.5 hours**. Note this supersedes the
planning figure carried until now: the 293 msg/min came from the Logic App pipeline, which
is a different path entirely. The export is roughly 11x faster, so this is a two-hour job
rather than the overnight-to-multi-day one previously assumed.

### Run it in Azure, not on the admin box

The deciding measurement is the write leg. This machine uploads to `samatters` at
**2.6 MB/s (21 Mbps)**:

```
export from Graph (4 workers) :  1.5 h
upload 121 GB from this box   : 13.4 h   <- nine times the export
```

Run locally, the upload *is* the job, and it pins a workstation for ~15 hours. Run in
**eastus alongside `samatters`** and the write is in-region, leaving wall-clock dominated
by the 1.5 h export.

**Azure Container Instance, not a Function.** Consumption Functions cap at 10 minutes; a
1.5 h run would need Durable fan-out, which is more machinery than a run-to-completion
batch job warrants. ACI is the smallest thing that fits. (The existing `RegExAzFunc`
zip-deploy pattern is a poor model here for the same reason.)

### Constraints the measurements impose

- **Batch 20, concurrency 4.** Both are measured ceilings. Raising concurrency to 8 is
  strictly worse - fewer items per minute *and* failures.
- **Handle 429 with `Retry-After`.** The 8-worker failures are the throttle speaking. At 4
  workers it stayed quiet across the sample, but a 310,000-item run will meet it.
- **Checkpoint per matter folder and resume.** `build-messageid-index.ps1` set the
  precedent - it was interrupted at 173,495 rows and continued without losing them. A
  1.5 h job that cannot resume is a job you run twice.
- **Append Message-ID index rows as it writes**, rather than leaving a 24-minute index
  rebuild behind.

### Unverified, and load-bearing

**The 1.5 h assumes MAPI->MIME conversion is cheap, which is not measured.** Conversion sits
between download and upload; if it is CPU-bound it becomes the bottleneck rather than the
network, and the ACI sizing follows from that. Benchmark it once a converter is chosen.

**121 GB is the exported size, not the stored size.** Converted MIME plus attachments
written as their own blobs will differ.

## Getting .eml out of the export

The route changed after the Graph `exportItems` payload turned out to be an MS-OXCFXICS
FastTransfer stream rather than MIME, and no tool could read it: Redemption is the only
library claiming FTS support and it fails on Graph's streams for 20 of 20 items, always on
the same construct (`Unexpected property type 0x33094040`, immediately after the named
property `ItemProcessorSuccess`). Its own FTS round-trips fine, so this is a Graph-vs-
Redemption incompatibility, reported upstream.

**The ingest therefore takes the eDiscovery Content Search route, which delivers PSTs.**

`pst-to-eml.ps1` does the extraction, using Redemption's `LogonPstStore` and `olRFC822`.
Not `readpst`: libpst has no official Windows build, and pypff/libratom ship no Windows
wheels, so pip tries to compile and fails on a box with no compiler and no elevation.
Redemption reads the PST through Outlook's own MAPI, so fidelity is native.

Verified end to end before any export existed, by pushing six real messages from the blob
container into a PST and pulling them back out:

```
Message-ID and sent date survived : 6 of 6
ingest-key.py tokens identical    : 6 of 6
timezone normalised correctly     : 10:33:58 -0700 -> 2026-05-04T17:33:58Z
```

So dedup and naming behave identically on export output and on existing archive content.

Two things to keep in view:

- **The MIME is regenerated, not copied.** 238,160 bytes in, 234,001 out on one sample.
  Content is equivalent, bytes are not. The live Logic App already stores
  Graph-generated MIME rather than a bit-exact original, so this is not a new property of
  the archive - but it should be stated rather than assumed.
- **Folder structure carries the matter.** A message's matter comes from the folder it
  sits in; that is the rule `sweep-older-mail.ps1` and `reconcile-missed.ps1` already use,
  and the only classification a person actually made. `pst-to-eml.ps1` mirrors the PST
  folder path into its output. Export the PST from Purview with **"Include folder and
  path of the source"** selected, or that information is destroyed before we see it.

Redemption is commercial and licensed per developer. It is now load-bearing for the
ingest rather than a discarded experiment, so the licence needs to be real before a
production run.

## Still open, and not decided here

- Attachments arrive inline in the extracted `.eml`. The existing archive also writes each
  attachment as its own blob under `Attachments/<token>/`, which the search skillset
  depends on, so the ingest still needs a step that splits them back out.
- Ingest scope: ~310,000 File Cabinet items, or 425,840 including the archive's Inbox and
  Deleted Items.

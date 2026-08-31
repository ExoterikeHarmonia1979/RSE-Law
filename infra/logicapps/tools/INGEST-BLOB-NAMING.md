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

Measured against the live tenant on 2026-08-31, not estimated.

### What the export API actually does

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

## Still open, and not decided here

- The export payload is an MS-OXCFXICS FastTransfer stream, **not MIME**. It cannot be
  written to `*.eml` as-is; the ingest needs a MAPI->MIME conversion step, or a deliberate
  decision to store a second format and teach both indexes about it.
- Attachments are embedded in that stream (confirmed present in 29 of 30 sampled items).
  They must be split back out to satisfy the `Attachments/<token>/` layout the search
  skillset depends on.
- Ingest scope: ~310,000 File Cabinet items, or 425,840 including the archive's Inbox and
  Deleted Items.

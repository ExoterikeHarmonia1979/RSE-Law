# Collapsing duplicate messages in the matters container

Design record for removing redundant copies of archived mail from `samatters/matters`.
Nothing here has been executed. It deletes client correspondence, so it does not run
without a dry run and explicit sign-off.

The trigger: the file tree and the search results both show the same message five or six
times. That is not a UI defect — they are genuinely distinct blobs, each with its own
index document.

## What was measured

From `infra/logicapps/tools/messageid-index.tsv` (built 2026-09-05, blob → Message-ID):

| | |
|---|---|
| Distinct Message-IDs | 577,121 |
| Mail blobs in the index | 660,009 |
| Message-IDs with more than one blob | 55,115 (9.5%) |
| **Redundant copies** | **82,888 — 12.6% of the archive** |
| Largest single group | 114 blobs of one message |

**Caveat on coverage.** The container listing holds 334,612 `.eml` + 362,523 `.msg` =
697,135 mail blobs, but the index has 660,009 rows — a gap of ~37,000. The index is also
three days old. Every number here is therefore approximate, and the cleanup must
re-derive its worklist from a freshly built index rather than trusting this file.

## Why the duplicates exist

Three mechanisms, which need different treatment.

**1. Ingested copies beside legacy ones — 23,854 groups.** A message exists both as a
Logic App blob (named by Graph message id) and as an ingested blob (named by the
`k`-token). The names differ, so the ingest wrote a second copy rather than overwriting.

This was predicted. `INGEST-BLOB-NAMING.md` states plainly: *"Existing blobs are not
renamed. All 258,974 keep their Graph-id tails."* The `k`-token makes the ingest
idempotent **with itself**, not with what was already in the container. The doc noted the
Message-ID index "already bridges the two identifier spaces" — the bridge was built, the
crossing never made. This cleanup is that crossing.

**2. The live pipeline duplicating — 22,314 groups.** Decoding the id tails on one
7-copy group gave prefixes grouped 3 + 2 + 1 + 1. A Graph message id is scoped to the
store *and folder*, so:

- four prefixes = four firm mailboxes, each archiving the same delivered message;
- three ids inside one prefix = the same item re-archived after retention moved it
  between folders.

**This one is ongoing.** A cleanup pass reclaims the backlog; it does not stop tomorrow's.
Fixing the source means keying the Logic App's blob name on the same `k`-token the ingest
uses, which is a separate piece of work and is not in scope here.

**3. Multi-matter filing — 8,947 groups.** The same message filed under two matters. This
bucket also contains the ~3,835 groups the project already documented where *genuinely
different* messages share one Message-ID, because Outlook reuses the header.

## Decisions

### Only collapse duplicates inside a single matter folder

| Scope | Groups | Ruling |
|---|---|---|
| Within one matter folder | 47,731 | Safe to collapse |
| Spanning two or more matters | 7,384 | **Excluded** |

A message appearing under two matters may have been filed there deliberately, and the
folder is the only classification a person actually made — `sweep-older-mail.ps1` and
`reconcile-missed.ps1` both already treat it that way. Deleting the "duplicate" would
silently remove a message from a matter someone put it in. Not worth the reclaim.

That leaves **73,307 deletable blobs** across 47,731 groups: 121,038 blobs collapsing to
one survivor each.

### Key on Message-ID *and* sent date, never Message-ID alone

Message-ID is not unique in this corpus — 3,835 documented groups of different messages
share one. The `k`-token rule (`sha256(lower(message-id) + '|' + sent-date-to-the-second)`)
is the identity that has already been validated on this data. The cleanup uses that key,
so those collisions are never treated as duplicates.

### Keep the copy whose bytes were not regenerated — CONFIRMED by the archive owner, 2026-09-08

Reviewed against 237 sampled groups before sign-off, every one of which showed this rule
making its choice. Approved as written.


Where a group mixes legacy and ingested copies, **keep the legacy blob**. The ingest
re-serialises MIME rather than copying it — `INGEST-BLOB-NAMING.md` measured 238,160
bytes in, 234,001 out. Content is equivalent; bytes are not. The legacy blob is what
arrived. For an all-legacy or all-ingested group, keep the oldest by `LastModified` and
break ties on blob name so the choice is deterministic and re-runnable.

### Never touch attachments in the flat layout

Two layouts coexist in the container, which the design doc does not mention:

| Layout | Blobs | Treatment |
|---|---|---|
| `<matter>/Emails/Attachments/<file>` | 172,542 | **Leave alone** |
| `<matter>/Emails/Attachments/<token>/<file>` | 90,839 | Delete with its message |

The flat form carries no message association at all, so there is no way to tell which
copy an attachment belonged to, and the surviving message may be the thing referencing it.
The tokened form is keyed by the message's id tail, so deleting a message without its
token folder orphans those blobs — and the search skillset indexes attachments as their
own documents, so orphans would keep appearing in results.

### Raise soft-delete retention before running — DONE 2026-09-08

The account had soft delete enabled at **7 days**, which is too short a window to notice a
problem across tens of thousands of deletions. Blob soft-delete retention is now **30
days**, with `allowPermanentDelete: false` preserved:

```
blobSoftDelete : { enabled: true, days: 30, allowPermanentDelete: false }
```

Leave it at 30 until the result has been reviewed. Container soft delete is untouched at 7
days, which is irrelevant here — this pass deletes blobs, never a container.

Blob versioning and change feed are both **off**, so soft delete really is the only
recovery path. That is also why the retention window is the whole safety argument: past
day 30 a wrong deletion is unrecoverable, so the review has to happen inside it.

## What the cleanup does

1. **Rebuild the Message-ID index** from the live container. Do not reuse the Sep-5 file.
2. **Group** by `sha256(message-id + '|' + sent-date)`, discarding any group whose blobs
   span more than one top-level matter folder.
3. **Choose one survivor per group** by the keep-rule above.
4. **Verify the survivor is readable** — fetch it and parse it — *before* deleting any of
   its siblings. A group whose survivor fails to parse is skipped and reported, never
   collapsed.
5. **Write a dry-run manifest**: every blob that would be deleted, its group, its
   survivor, and why. This is the artefact that gets reviewed and signed off.
6. **Delete in batches with a checkpoint**, so an interrupted run resumes without
   re-deriving. `ingest-run.ps1` sets the precedent.
7. **Let the indexer clean the index.** The datasource carries
   `NativeBlobSoftDeleteDeletionDetectionPolicy`, so soft-deleted blobs drop out of the
   index on the next run. `purge-index-orphans.ps1` is the backstop if any survive.

## Unverified, and load-bearing

~~**Nobody has confirmed the copies are actually the same message.**~~ **Done.**
`dedup-plan.py review` sampled **237 groups**, stratified toward mixed-scheme groups (where
the keep-rule actually chooses) and the largest groups (where a wrong choice costs most).
All 237 agreed on sender, sent date and subject; consecutive seeds were checked for overlap
and shared no groups. `selftest` separately proves the identity function reproduces the
tokens already written into ingested blob names.

Two apparent disagreements turned out to be artefacts of the comparison, not the data, and
both are now handled: the mail gateway prepends `[EXTERNAL] ` per recipient, so one
delivered copy carries it and another does not; and the `.msg` side returns RFC 2047
encoded-words where the `.eml` side returns decoded text.

**237 is 0.5% of the 47,121 groups.** What covers the rest is different evidence: the
identity function is verified, and every one of the 47,121 groups has exactly one survivor.

**The reclaimed size is unknown.** Every figure here is a blob count. Nobody has summed the
bytes, so the actual storage saving is unmeasured.

## Out of scope

- Stopping mechanism 2 at source, by keying the Logic App's blob names on the `k`-token.
  Until that lands, duplicates keep accruing at the rate the firm receives shared mail.
- Cross-matter duplicates (7,384 groups).
- De-duplicating the flat attachment layout.
- Collapsing duplicates in the web part's UI, which would hide the symptom while the
  storage and indexing cost continues.

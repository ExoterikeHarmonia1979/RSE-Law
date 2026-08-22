# tools

Operational scripts from the 2026-08 archive recovery. They are here because several of them
performed irreversible work and someone will eventually need to know exactly what was done
and on what evidence.

All are read-only unless they take `-Execute`. Every destructive one dry-runs by default.

## The problem these were written for

Accounting reported the SharePoint search returning far fewer results than the matters
mailbox. Two causes, both measured:

1. **The archive only ever read the Inbox.** `matters@rse-law.com` holds ~198,000 messages
   across ~880 folders; ~120,000 of them sit in a `File Cabinet/<series>/<matter>` tree that
   staff file by hand. 60% of the mailbox had never been archived.
2. **Blob names were the subject alone**, so every reply in a thread overwrote the one before
   it. Matter 120.058 held 53 files representing 16 actual conversations.

## Diagnosis

| | |
|---|---|
| `matter-gap.ps1` | For one matter: searches the mailbox as Outlook does and decomposes the gap - which folder each message is in, whether the matter appears in the subject, and how many distinct conversations the messages collapse to. This is what proved folder scope mattered more than threading. |
| `coverage.ps1` | Tests the shipped `CaseClaimNoPatterns` / `RSEFileNoPatterns` arrays against live list data and shape-profiles whatever they miss. Patterns are read from the `.cs` files so it tests what actually ships. |
| `collision-truth.ps1` | Answers "would two messages overwrite each other?" by reconstructing real blob names. **Deduplicate by message id first** - Graph paging returns the same message twice, which reported 3,327 collisions where there were none. |

## Blob de-duplication

Ran once: 28,915 blobs removed, 1,427 correctly spared.

| | |
|---|---|
| `dedup-counts.ps1` | Classifies old-format blobs as superseded or orphaned by subject stem. **Its output is not safe to delete from** - see below. |
| `verify-superseded.ps1` | Samples that classification and checks it by RFC 5322 Message-ID. Found 2 in 30 were *not* redundant. |
| `verify-all.ps1` | Verifies every candidate by Message-ID. Of 30,342 stem-matched candidates, **1,427 were different messages** - subject-stem matching is too coarse to delete on. |
| `delete-proven.ps1` | Deletes only what `verify-all` proved. Refuses if any path carries a ` [id].eml` suffix (that would delete the copy making the old one redundant), if anything is not a matter email, or if soft delete is off. |

## Teams retirement

676 matter-named Teams (519.7 GB reported, 8.11 GB live - the rest was version history) were
deleted on 2026-08-22 after their content was proven redundant.

| | |
|---|---|
| `teams-inventory.ps1` | Full inventory of every file in every matter Team. Result: 12,206 files, 100% `.eml`, no working documents. |
| `teams-vs-archive.ps1` | Matches Teams mail against the archive by Message-ID. Caches the archive side - that phase costs ~30 min and a later failure should not force a redo. |
| `resolve-unverified.ps1` | Resolves every file to a definite state and **persists a result per file**. Falls back to a full download and MimeKit parse when a ranged regex cannot find the header, then to a hash. Written because the first pass left 153 files unresolved and saved no way to identify them. |
| `upload-teams-only.ps1` | Uploads mail that existed only in Teams, filed under the Team's matter number, with attachments extracted via MimeKit to match `Create_blob_for_Attachment`. |
| `delete-teams.ps1` | Deletes the groups. Writes a manifest **before** deleting, and refuses unless every target is matter-named and was previously inventoried. |

Final state: 11,421 matched, 672 uploaded, 113 proven not to be email, **0 unresolved**.

The 113 are worth knowing about: they are Graph `ErrorItemNotFound` payloads that the old
Power Automate flow wrote into `.eml` files without checking the response status. Two distinct
hashes across all 113. No message was ever saved for them.

Accepted losses, recorded because they are irreversible after the 30-day window:
161 attachments exist only inside their `.eml` rather than as separate blobs, and SharePoint
version history was never archived.

**The restore manifest is NOT in this repo** - it holds staff email addresses. It is at
`OutlookSearchSPFxWebPart/FIles/deleted-teams-manifest-2026-08-22.csv`, which `.gitignore`
excludes. Deleted groups are restorable until **2026-09-21** via
`POST /directory/deletedItems/{id}/restore`.

## Missed notifications

Graph does not always deliver the change notifications it promised. When it gives up it
sends a lifecycle notification instead:

```json
{"type":"Missed", "data":{"SubscriptionId":"...", "lifecycleEvent":"missed", "resourceData":null}}
```

That is Graph saying *mail arrived on this subscription and we failed to tell you about it*.
It does not say which mail, or how much. The archive workflow finds no OData ID in the
payload, skips it, completes it off the queue and reports **Succeeded** - so the mail behind
it is never archived and nothing anywhere records that it existed.

Measured over 600 runs spanning 3.7 hours: **21 Missed events across 14 subscriptions**,
about **137 a day**.

The obvious fix - look the subscription up and re-sync just that resource - does not work
here. Of those 14 subscription ids, 13 no longer existed by the end of the same window: the
renewal job replaces subscriptions rather than extending them, so ids churn continuously and
a Missed event is usually unresolvable to a mailbox after the fact.

So reconciliation is **per mailbox, not per subscription**, and runs on a trailing window
whether or not a Missed event was seen. That also recovers mail lost to throttling, transient
Graph failures and expired subscriptions, none of which announce themselves either.

| | |
|---|---|
| `reconcile-missed.ps1` | Compares every subscribed mailbox against the archive over a trailing window and enqueues what is absent. Absence is by **message-id tail**, the same identity the blob names carry - never by subject or date. Dry run unless `-Execute`. |
| `run-reconcile-scheduled.ps1` | Scheduled-task wrapper. Runs a 3-hour window every 2 hours so consecutive runs overlap, logs each run, prunes logs after 30 days. |

Installed as scheduled task **`RSE-Archive-Reconcile`**, every 2 hours.

Two details that matter if you change this:

- It **skips Drafts, Junk, Deleted Items** and the rest of the non-correspondence folders.
  The live path only ever sees `created` notifications, so it never offers mail the user has
  since binned; a reconciler sees mail where it sits *now* and without this would archive it.
- It takes the Service Bus key from `az`, not from `%TEMP%\sbkey.txt` like `sweep-inbox.ps1`.
  A temp file is fine for a hand-run sweep and useless for a scheduled job - it would fail at
  the enqueue, after doing all the work.

First run recovered **244 messages** from an 8-hour window. The 42 that remained were all
`eventMessageRequest` / `eventMessageResponse` - calendar items, which the firm does not want
archived - and 42 more were skipped as bins and drafts. No ordinary mail was left behind.

## The lesson that recurs

Every serious bug here was **a failure recorded as data**:

- a dropped `x-ms-version` header made 195,815 auth failures look like "no Message-ID", which
  would have classified all 12,206 Teams emails as missing and duplicated the corpus
- Graph throttling made 11,197 reads look like unmatched mail
- Graph paging duplicates looked like blob-name collisions
- subject-stem matching made 1,427 distinct messages look redundant
- and the old flow itself wrote 404 responses into `.eml` files
- a `Missed` notification - Graph *reporting its own failure* - was read as "no message here"
  and completed off the queue as a success

The scripts therefore record *why* something failed rather than returning an empty result,
and abort rather than emit a plausible-looking wrong answer. Keep that property.

# Blob naming for the archive ingest

Decision record. No ingest code exists yet; this settles the identifier it must use,
because that choice constrains dedup, attachment layout and re-runnability, and is
expensive to change once blobs are written.

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

## Still open, and not decided here

- The export payload is an MS-OXCFXICS FastTransfer stream, **not MIME**. It cannot be
  written to `*.eml` as-is; the ingest needs a MAPI->MIME conversion step, or a deliberate
  decision to store a second format and teach both indexes about it.
- Attachments are embedded in that stream (confirmed present in 29 of 30 sampled items).
  They must be split back out to satisfy the `Attachments/<token>/` layout the search
  skillset depends on.
- Ingest scope: ~310,000 File Cabinet items, or 425,840 including the archive's Inbox and
  Deleted Items.

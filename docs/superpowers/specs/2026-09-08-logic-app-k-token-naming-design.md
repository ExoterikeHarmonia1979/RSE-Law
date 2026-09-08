# Naming archived mail by the message, not by the mailbox it arrived in

Design record for changing the Logic App archive pipeline to name blobs by the `k`-token —
`sha256(lower(message-id) + '|' + sent-date-utc-to-the-second)` — instead of the tail of the
Graph message id. Nothing here is implemented.

## The problem

The blob name is built in `transform.ps1:329`:

```
idTail = last 24 chars of the Graph message id, '/'->'_', '+'->'-', '=' dropped
name   = <matter>/Emails/<subject capped 150> [<idTail>].eml
```

That comment block is right about what it set out to do — it made the name unique per
*message* rather than per subject, which fixed a real bug where every reply in a thread
overwrote the one before it. But **a Graph message id is scoped to the store and the
folder**, so the same message carries a different id in every mailbox that received it, and
a different one again after retention moves it. The name is therefore unique per *copy*,
not per message.

Measured consequence, from the duplicate analysis in
`2026-09-08-duplicate-blob-cleanup-design.md`: **22,314 duplicate groups** produced by this
mechanism. Decoding one 7-copy group gave id prefixes grouped 3 + 2 + 1 + 1 — four
mailboxes, and three copies inside one of them from folder moves. Unlike the ingest's
duplicates, this mechanism is **ongoing**: it produces new duplicates every day the firm
receives mail addressed to more than one person.

The ingest already solved this for its own writes with the `k`-token. This brings the live
pipeline onto the same identity.

## What makes this awkward

**Logic Apps cannot hash.** The workflow definition language has `concat`, `substring`,
`replace`, `base64` — and no hashing function of any kind. `$idTail` is pure string
surgery, which is why it could be inlined. A `k`-token cannot be. It requires a call out.

**The pipeline does not have the inputs.** `Get_Message_ID` is
`body('Parse_JSON')?['Data']?['ResourceData']?['Id']` — the Graph id lifted from the change
notification. Neither `internetMessageId` nor `sentDateTime` appears anywhere in the
workflow. What the pipeline *does* have is the raw MIME, fetched from Graph as `$value`.

**The rule is duplicated in four places.** `transform.ps1`, `sweep-inbox.ps1`,
`tools/sweep-older-mail.ps1` and `tools/reconcile-missed.ps1` each reimplement `Get-IdTail`,
three of them carrying a comment reading *"MUST match transform.ps1's $idTail exactly."*
They predict blob names to decide what is already archived. Changing the pipeline alone
would make them stop recognising archived mail and re-upload it — turning a duplication
problem into a much larger one.

**Name uniqueness is the only protection there is.** `transform.ps1` records that the
storage account has hierarchical namespace enabled, so Azure blob versioning is
unavailable on it (`FeatureNotSupportedForAccount`). This is a stronger constraint than the
cleanup spec assumed when it described versioning as merely "off".

## Decisions

### The Function takes the raw message bytes, not extracted fields

`DedupTokenFunc` receives the MIME the pipeline already holds and does the whole
derivation: strip control characters from the Message-ID, normalise the `Date` header to
UTC to the second, hash. Same extraction, same source, same rule as `ingest-key.py`.

Rejected: the cheaper-looking design where the caller fetches
`?$select=internetMessageId,sentDateTime` from Graph and posts two short strings. That
introduces a **second source of truth for the sent date**. Every one of the 401,170
ingested tokens was derived from the `Date:` header *in the message*; Graph's
`sentDateTime` is Exchange's own record of when it sent. They are usually the same instant,
and there is no evidence they always are. A one-second disagreement gives the same message
two different tokens — reintroducing the exact defect this work exists to remove.

The cost is real and accepted: the pipeline posts ~500 KB per message to the Function,
doubling data movement per archived email. It is in-region.

```
POST /api/DedupTokenFunc              body: raw .eml/.msg bytes
  -> 200 { "token": "k3f9a…", "messageId": "…", "sentUtc": "2026-03-20T21:52:57Z" }
  -> 422 { "error": "no Message-ID" }        identity not derivable

POST /api/DedupTokenFunc?from=fields  body: [{ "id": "…", "messageId": "…",
                                               "sentDateTime": "2026-03-20T21:52:57Z" }, …]
  -> 200 [{ "id": "…", "token": "k…" }, …]
```

### The sweeps get the cheap route the pipeline cannot have

The two endpoints exist because the callers can tolerate different things, and flattening
them into one would either cripple the sweeps or endanger the pipeline.

A sweep decides "is this message already archived?" by building a set of identifiers from
blob names — `\[([^\]]+)\]\.eml$`, which already captures `k`-tokens as readily as legacy
tails, so that side needs no change — and then computing the identifier for each Graph
message. Computing it from raw bytes would mean fetching `$value` for every message in a
198,000-message walk. That is not affordable.

`sentDateTime` comes free in the `$select` the sweeps already issue. It is not safe for the
pipeline, where a wrong token writes a mis-named blob and creates a real duplicate. It **is**
safe for a sweep, because of an asymmetry worth stating plainly:

> A sweep that computes the wrong token sees a false "missing" and re-queues the message.
> The Logic App then archives it under the **authoritative** token — the same name it
> already has — and overwrites. The `k`-token is idempotent by construction: same message,
> same name, same matter. A sweep's wrong token costs bandwidth, never a duplicate.

Both endpoints share one normalisation-and-hash implementation, so "one implementation"
still holds; only the source of the two inputs differs.

**Before either is wired up, measure how often `sentDateTime` disagrees with the `Date:`
header.** If they agree, the sweeps are exact. If they disagree often, every sweep
re-queues most of the recent corpus — a throughput regression that should be known before
shipping rather than discovered in production. The measurement is a task in the plan, and
it gates the design rather than decorating it.

Rejected: matching on Message-ID alone, which would need no date and no hash. It collides
on 3,835 groups in this corpus, and a false "already archived" **drops a message**. That is
the one failure this archive cannot tolerate; a redundant re-archive is merely wasteful.

### One implementation, not three

The token would otherwise exist in Python, C# and PowerShell, and any two drifting by one
character silently breaks dedup — the failure this whole effort is meant to end. So the C#
Function is the only place the hash lives. The PowerShell predictors call it.
`ingest-key.py` stays as it is, because 401,170 blob names already encode its output; it
gains a conformance test rather than a rewrite.

**The conformance test is what makes "one implementation" true rather than aspirational.**
`dedup-plan.py selftest` already proves tokens against real ingested blob names. The
Function must clear the same bar — recompute tokens for a sample of ingested blobs and
match the token in each name — before anything is wired to call it.

### A naming call must never lose mail

On Function failure, timeout, or a `422`, the Logic App **falls back to today's `$idTail`
naming** and archives normally.

Prefer a duplicate over a loss. A duplicate is recoverable and there is now tooling that
finds and collapses them; a message that never reached the archive is not. This pipeline
has form here — `For_each_Attachment` dead-lettered mail after ten retries when an
attachment list came back null. A naming optimisation must not be able to do that.

So the Function is best-effort. The worst case is degrading to exactly today's behaviour.

Measured, on the population that matters — the 258,974 `.eml` blobs are Graph-generated
MIME written by this same pipeline:

| Format | Rows | No usable Message-ID |
|---|---|---|
| `.eml` | 258,974 | **135 (0.052%)** |
| `.msg` | 401,170 | 0 |

The fallback fires on roughly 1 message in 1,900. Note this does *not* inherit
`ingest-key.py`'s observation that 26% of `.msg` needed a MAPI-property fallback for
internal mail with no SMTP headers: Graph synthesises a Message-ID when it generates MIME.

### Attachments follow the message, and the choice is atomic per message

`transform.ps1:407` writes attachments to
`/matters/<matter>/Emails/Attachments/@{$idTail}/`, keyed by the same identifier as the
`.eml`. So the attachment folder moves to the `k`-token with the message. This is forced
rather than preferred: leaving attachments on the Graph-id tail while the message is named
`… [k3f9a…].eml` would sever the only link between them, since neither identifier is
derivable from the other.

**The identifier is chosen once per message and used for both.** When the Function is
unavailable and the message falls back to `$idTail`, its attachments use `$idTail` too. A
message must never be written with a `k`-token `.eml` and an `$idTail` attachment folder;
that is worse than either scheme applied consistently.

Consequence, accepted: this is a third attachment layout. The cleanup spec already found
two coexisting — 172,542 flat (`Attachments/<file>`, carrying no message association at
all) and 90,839 tokened. Adding `Attachments/<k-token>/` does not help that mess, but the
alternative is a message whose attachments cannot be found from its name.

### Predictors check both naming schemes, permanently

Every script that predicts a blob name computes **both** the legacy tail and the `k`-token,
and treats the message as archived if either exists.

This is not a transition measure. The 258,974 existing legacy-named blobs are never
renamed — `INGEST-BLOB-NAMING.md` settled that, and renaming would churn the search index
for no functional gain. The two identifier spaces coexist for good.

It also resolves an interaction that would otherwise oscillate. The cleanup keeps the
*legacy* copy where a group mixes schemes (confirmed by the archive owner, 2026-09-08). If
a predictor checked only the `k`-token, it would find nothing, re-upload, and the cleanup
would delete it again — forever. Checking both names closes the loop.

## Rollout order

Not negotiable, because two of the orderings create duplicates in the window between steps.

1. **Ship `DedupTokenFunc`.** Nothing calls it. Prove it against `ingest-key.py`'s output
   on real ingested blob names.
2. **Teach the predictors both schemes.** They now recognise `k`-token blobs that do not
   exist yet, which is harmless.
3. **Switch the Logic App.** New mail lands under `k`-token names, which the predictors
   already understand.

Reversing 2 and 3 means every sweep between them re-uploads mail the pipeline just archived
under a name the sweeps do not recognise.

## Files

| Path | Change |
|---|---|
| `RegExAzFunc/DedupTokenFunc.cs` | new — the single implementation |
| `RegExAzFunc.Tests/DedupTokenFuncTests.cs` | new — conformance against real ingested tokens |
| `infra/logicapps/transform.ps1` | call the Function; fall back to `$idTail` |
| `infra/logicapps/sweep-inbox.ps1` | check both names |
| `infra/logicapps/tools/sweep-older-mail.ps1` | check both names |
| `infra/logicapps/tools/reconcile-missed.ps1` | check both names |
| `infra/logicapps/tools/ingest-key.py` | unchanged |

## Unverified, and load-bearing

**No one has confirmed a Logic App can post a chunked `$value` response body to a Function
and read a field back from the reply.** The workflow already fetches `$value` with
`transferMode: Chunked` and writes it to blob storage, so the bytes are demonstrably
available to actions — but "available to the blob connector" and "postable as an HTTP body"
are not the same claim. This is the first thing to test, because if it fails the whole
design changes: the fallback would become the norm, and the alternative is the Graph
`$select` route with its sent-date risk.

**The 500 KB per message figure is the ingest's measured average item size**, not a
measurement of this pipeline's traffic. Actual cost may differ.

**Whether Graph's `sentDateTime` matches the `Date:` header is unmeasured**, and the
sweeps' efficiency rests entirely on it. Nothing breaks if they disagree — the idempotency
argument above holds either way — but the sweeps would re-queue most of the recent corpus
on every run. Measure before wiring, not after.

**The blast radius of a wrong token is larger than it looks.** A message named under a
token that disagrees with the ingest's is not merely a duplicate — it is a duplicate whose
attachments also sit under a folder nobody else derives. The conformance test is the only
thing standing between a subtle hash disagreement and a second, quieter version of the
problem being fixed here.

## Out of scope

- Renaming the 258,974 existing legacy-named blobs.
- The duplicate cleanup itself, which is a separate spec and already has a signed-off
  manifest.
- Teams-only upload (`tools/upload-teams-only.ps1`), which derives names differently and
  does not participate in this identity.

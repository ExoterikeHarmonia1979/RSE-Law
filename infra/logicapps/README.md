# HTTP-Matter-On-Email-Receipt

> This folder now holds two workflows. The other one, `Matters-Lookup-Sync`, feeds the
> matter lookup list this one reads — see `Matters-Lookup-Sync.md`. `deploy.ps1` and
> `drift.ps1` are shared; `validate.ps1` is specific to the workflow documented here.

Files incoming matter email into blob storage. Consumes the `speventgridqueue` Service Bus
queue, which is fed by Graph mail change-notification subscriptions across ~95 mailboxes via
partner topic `GETopicRSEShared`.

| | |
|---|---|
| Resource group | `Sharepoint1` (eastus), subscription `66268ff4-…` (RSE-Sharepoint) |
| Managed identity | `30701da1-0d55-454a-bf67-bfdd70f93a76` — Key Vault Secrets User on `kv-rse-graphsubs`, `Mail.Read` on Graph |
| Queue | `speventgridqueue` / namespace `SharePointExchangeEventGrid` |
| Blob target | `samatters`, container `matters` |
| Matter lookup | SharePoint list `940d4826-…` on site `MatterExchange-POC` |

## Working on it

The definition is source of truth here, not the portal. 57 actions with a hand-wired
`runAfter` graph is not a point-and-click change.

```powershell
./transform.ps1              # before.json -> after.json
./validate.ps1               # must print ALL CHECKS PASSED before deploying
./deploy.ps1                 # dry run: reports drift and what would change
./deploy.ps1 -Execute        # PUT, refusing if live has drifted
```

`validate.ps1` is not decoration. It catches the mistakes that are invisible in the designer
and only surface in production. One of them it now catches was live in this repo for weeks:
`after.json` was emitting `"runAfter": { "X": "Succeeded" }` instead of `["Succeeded"]`,
which ARM rejects outright, so the generated definition could not be deployed at all. The
cause was in `Test-JsonScalar` — PowerShell enumerates member access over a collection, so
on a one-element array `$o.psobject.BaseObject` returns the *element's* BaseObject, the
array tested as a scalar, and the scalar return path unwrapped it. Only single-element
arrays were affected, which is why it went unnoticed. Checks:

- a `runAfter` naming a deleted action, or an expression referencing one
- `filter(...)` / `select(...)` used as expressions — **these are actions in Logic Apps**
  (`Query` / `Select`), not functions, and the designer will accept them happily
- an `AppendTo*Variable` inside a parallel loop — Logic App variables are not concurrency-safe,
  so this drops items, it does not merely reorder them
- a `Terminate` that does not follow a Complete/Abandon, which would end a run with the
  message still locked

Deploy with `deploy.ps1`, not a hand-rolled PUT. A PUT is a full replace, and two ways of
losing work are easy to hit by hand:

- **omitting `identity` strips the managed identity** every Graph call authenticates with
- **`before.json` is a one-time snapshot.** Anything changed directly on the live workflow and
  not mirrored into `transform.ps1` is silently reverted by the next deploy. This is not
  hypothetical: the trigger concurrency was 100 live and 40 in the repo, and a redeploy would
  have quietly halved throughput with nothing in the output to say so.

`deploy.ps1` handles the first and detects the second. It keeps `deployed.json` — the definition
as the tooling last PUT it — and compares live against *that*, not against the new definition
(every intentional change is also a difference, so comparing forwards detects nothing). If live
has moved out from under the baseline it names the paths and refuses, until you either mirror
the change into `transform.ps1` or pass `-AcceptDrift` to discard it.

`deployed.json` is committed on purpose. It is shared state: a baseline only anyone's local
machine knows about cannot tell you that someone else edited the portal.

`transform.ps1` runs the same check before it overwrites `after.json`, because by the time
`deploy.ps1` blocks the PUT the generated file already disagrees with live and the reason is
easy to miss. Pass `-AcceptDrift` to discard the live change, or `-NoDriftCheck` to work with
no Azure access. The shared logic is in `drift.ps1` — one copy, so the two scripts cannot
disagree about what counts as an out-of-band edit.

`after.json` is emitted with keys sorted, so regenerating it twice produces identical bytes.
Without that, `ConvertFrom-Json -AsHashtable` reshuffles keys on every run and a one-line
change arrives as ~538 changed lines — which is how a live-vs-repo difference gets through a
review unnoticed.

## What it does

```
peek-lock trigger (concurrency 100)
└ Process_Message (scope)
    ├ decode Service Bus payload -> Graph message id + OData id
    ├ fetch message, recipients, attachments   (Graph, managed identity)
    ├ resolve the matter:
    │    regex on subject -> one SharePoint lookup
    │    else split subject -> ONE OR'd $filter lookup -> first match in subject order
    └ if matter found and not a calendar item:
         write <subject>.eml and attachments to /matters/<matter>/Emails[/Attachments]/
├ Succeeded            -> Complete the message
└ Failed / TimedOut    -> 404? Complete (stale notification)   else Abandon -> redeliver
```

## Things that will bite you

**The mailbox is not the Inbox.** `matters@rse-law.com` holds ~198,000 messages across ~880
non-empty folders, and only ~78,000 of them are in the Inbox. The rest sit in a `File
Cabinet/<series>/<matter>` tree that staff file into by hand. Until 2026-08-20 the sweep
walked `Inbox` only, non-recursively, so **60% of the mailbox had never been archived at
all** — which is why users found far more in Outlook than in the search web part, and it is
a much larger effect than the thread collapse described above.

Measured on matter 119.014 when this was found: 272 messages mentioned it, 205 of them in
`File Cabinet/119/119.014`, only 12 in the Inbox, and **none of those 12 carried the matter
number in the subject** — so the sweep had filed nothing. The archive held 16 emails and the
search returned 19 hits, against 271 in Outlook.

**That folder tree is a matter classification somebody already made**, on ~119,600 messages,
and the pipeline used to ignore it. `sweep-inbox.ps1 -AllFolders` now passes the folder's
matter number as `Data.MatterHint`, and the workflow uses it *only* when subject matching has
already failed (`If_No_Matter_Use_Folder_Hint`). Real Graph notifications carry no hint and
behave exactly as before. This matters because the subject often does not name the matter at
all: 52 of those 272 messages mention 119.014 only in the body or an attachment.

**Most notifications are not archivable, and that is normal.** Roughly half of what arrives is
a change notification for a message that no longer exists at that id — a draft that was sent, a
message moved or deleted. Graph returns 404. These are completed, not retried: retrying cannot
help, and abandoning them burns all 10 deliveries and dead-letters a no-op. If the failure rate
climbs, check whether it is *this* rather than assuming the archive is broken.

The upstream fix is narrower subscriptions — they currently cover `created` and `updated`
across all folders, so Drafts and Sent Items generate events that can never be archived. See
`RegExAzFunc/docs/GraphSubscriptions.md`.

**Message durability depends on three things together.** Peek-lock alone still loses mail to
TTL; dead-lettering on expiry alone still loses mail to failed runs. Currently: peek-lock with
explicit complete/abandon, `deadLetteringOnMessageExpiration=true`, `lockDuration=PT5M`,
`maxDeliveryCount=10`, TTL 14 days.

`lockDuration` must exceed real run time. At `PT1M` the slowest runs lost their lock before
completing and the message was redelivered while still being processed.

**The blob name must stay unique per message.** It is
`<sanitised subject, capped 150> [<last 24 chars of the Graph message id>].eml`. The suffix
is not decoration. Until 2026-08-20 the name was the subject alone, so every reply in a
thread wrote to the same path and silently overwrote the one before it — the archive kept
one message per *subject*, not per message. Measured on matter 120.058: 53 stored files
representing 16 actual conversations, with the surviving copies quoting threads 30 messages
deep. That is why the search web part returned far fewer hits than the matters mailbox, and
it is what accounting reported.

Keep the suffix deterministic. The same message must always land on the same blob or
`replay-dlq.ps1`, `recover-failed-runs.ps1` and `sweep-inbox.ps1` stop being safe to re-run.

Versioning cannot save you here: the storage account has hierarchical namespace enabled, so
Azure blob versioning is unavailable (`FeatureNotSupportedForAccount`) and an overwrite
leaves no trace at all. Uniqueness in the name is the only protection there is.

**Attachments are one folder per message**, not one flat folder per matter:

```
/matters/<matter>/Emails/Attachments/<message-id tail>/<filename>
```

Until 2026-08-22 they were named by attachment name alone, so two different emails in one
matter both attaching `Invoice.pdf` or `image001.png` overwrote each other — the same silent
defect as the subject-only `.eml` names, and it lost real attachments the same way.

A subfolder rather than a name suffix, deliberately: a downloaded file keeps its real name.
The segment is the same deterministic message-id tail the `.eml` uses, so an attachment sits
beside its own message and a re-run overwrites its own blob rather than duplicating.

Nothing reads these by path — `EmlPreviewFunc` and `EmlAttachmentNamesSkill` parse
attachments out of the `.eml`, the index takes `attachment_names` from that skill, and
`refile-unsorted.ps1` excludes anything below the prefix either way. Attachments written
before the change stay flat; only new writes nest. `validate.ps1` check `[9b]` asserts both
blob paths still carry the message id.

**`strFoundMatter` is the blob path.** If it is ever empty the archive writes to
`/matters//Emails/` and still reports success. There is a guard on the condition; do not
remove it.

**Attachment loops are sequential on purpose.** `For_each_Attachment` appends to a shared array
variable. Parallel is faster and silently loses attachments.

## Recovery

```powershell
./replay-dlq.ps1 -Max 400 -Execute          # dead-letter queue -> main queue
./recover-failed-runs.ps1 -Execute -MaxPages 80   # re-enqueue payloads behind failed runs
```

Both are safe to re-run: blob names are deterministic (matter + sanitised subject), so
reprocessing overwrites rather than duplicates.

`resubmit` is **not** usable for runs predating 2026-08-08 — the trigger was renamed when it
moved to peek-lock, which orphans their trigger history. Re-enqueueing the payload is the
route, and it also puts the message back under the peek-lock guarantees.

Run history is finite and is consumed quickly under load. A high-volume drain will push older
failed runs out of reach, so recover before draining, or page deeper (`-MaxPages`).

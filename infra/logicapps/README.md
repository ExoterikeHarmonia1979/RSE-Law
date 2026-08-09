# HTTP-Matter-On-Email-Receipt

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
and only surface in production:

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

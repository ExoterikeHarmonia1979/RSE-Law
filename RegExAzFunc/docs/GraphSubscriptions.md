# Graph mail subscriptions — operations guide

Keeps a Microsoft Graph change-notification subscription alive for every active mailbox at
RSE Law, so new mail raises an Event Grid event that lands on the
`speventgridqueue` Service Bus queue and gets archived.

Replaces the Power Automate flow **“Sched Renew Graph API Subscription”**
(`a55efb24-7efb-48a5-8e8e-6ab5b3fdcf43`).

---

## How it fits together

```
GraphSubNightly (22:00 local)
   └─ enumerate active users ──────────────► Microsoft Graph  /users
   └─ list owned subscriptions ────────────► Microsoft Graph  /subscriptions
   └─ create / renew / repair ─────────────► Microsoft Graph  /subscriptions
   └─ activate topic + wire queue ─────────► ARM  Microsoft.EventGrid/partnerTopics
   └─ publish arrUsers projection ─────────► blob  config/arrUsers.json
   └─ email summary ───────────────────────► Graph  /users/{from}/sendMail

new mail ─► Graph ─► partner topic GETopicRSEShared ─► event subscription
        ─► Service Bus queue speventgridqueue ─► archive consumer
```

| Function | Trigger | Purpose |
|---|---|---|
| `GraphSubNightly` | Timer `0 0 22 * * *` local | The job. Reconcile → create → renew → repair → publish → email. |
| `GraphSubNightlyManual` | `POST /api/graphsubs/nightly?dryRun=false` | Same work on demand. Defaults to **dry run**. |
| `GraphSubReconcile` | `POST /api/graphsubs/reconcile` | Onboarding / ad-hoc. Body `{ roster, dryRun, deleteOrphans, skipRenew }`. |
| `GraphSubStatus` | `GET /api/graphsubs/status` | Counts, next expiry, drift timestamp. |
| `GraphSubUsers` | `GET /api/graphsubs/users` | The frozen `arrUsers` envelope. |
| `GraphSubLifecycle` | `POST /api/graphsubs/lifecycle` | Event Grid `subscriptionReauthorizationRequired`. |

---

## Five facts that drive the design

Each of these was measured against the live tenant, and several contradict the documentation.

1. **Subscriptions belong to the app that created them.** `GET /subscriptions` returns only
   those whose `applicationId` matches the caller; `PATCH`/`DELETE` on another app's
   subscription returns 404. The Function **must** run as
   `43248a7a-1c76-40fd-91b6-57ec5f08639e`. An empty subscription list almost always means
   the wrong identity, not an outage — the engine logs a warning and refuses to treat it as
   a green field.

2. **An orphaned partner topic is permanent poison.** When a subscription lapses, its topic
   remains in `Succeeded` state. Creating a new subscription under that topic name then
   fails with `400 StoreBadRequest — "…already present…"`, forever. The old flow swallowed
   that error, so mailboxes dropped off one at a time and never returned: **41 of 73 were
   dead** when this work started. Consequences, both enforced in code:
   - deleting a subscription always deletes its per-user topic (`DeleteWithTopicAsync`);
   - a `StoreBadRequest` on create triggers delete-stale-topic-and-retry, and is never
     swallowed.

3. **Many subscriptions can share one partner topic.** Not documented; proven in a two-mailbox
   pilot. This is what makes `TopicNaming=Shared` possible and removes the per-user topic
   sprawl (72 topics + 72 event subscriptions, all feeding the same queue anyway).

4. **`changeType: "Created"` works on the Event Grid transport.** The Event Grid docs claim
   `Created` is unsupported; all live subscriptions persist it and deliver. Do not "fix"
   this — dropping `Created` would stop new-mail events, which is the entire point.

   `Updated` **was** subscribed alongside it until 2026-08-08, and was removed. It fires on
   every read, flag and move, and because archive blob names are deterministic (matter +
   sanitised subject) each one re-downloaded the message from Graph and overwrote a blob that
   was already correct. Measured against live traffic before the change:

   | | |
   |---|---|
   | share of all queue events that were `updated` | **87%** |
   | archiving runs sampled / distinct blobs written | 84 / **7** |
   | most re-archived single email | **44 times** |

   Do not add it back to guard against a missed message. The queue consumer is peek-lock and
   retries a failed message up to `maxDeliveryCount` before dead-lettering it, so a transient
   failure on the `Created` event is already covered — without duplicating every subsequent
   event for the life of that message.

   Set via `GraphSub__ChangeTypes` (default `Created`).

5. **Max subscription lifetime is 7 days**, and a requested `now + 6 days` is granted
   verbatim. Renewing to 6 days means **six consecutive missed nightly runs** before
   anything lapses. The old flow renewed to ~2.9 days, giving barely two.

Related: a new topic lands `NeverActivated` and self-destructs after 7 days; activation is
immediate but **event subscription creation is async** and must be polled to `Succeeded`.
A subscription whose topic is unactivated or unwired looks perfectly healthy and delivers
nothing, so the engine only reports `created` once delivery is actually possible.

---

## Configuration

All settings are `GraphSub__*`; see `local.settings.json` for the annotated full list.
The ones you must get right:

| Setting | Value | Notes |
|---|---|---|
| `GraphSub__ClientId` | `43248a7a-…639e` | The owning app. Do not change. |
| `GraphSub__TenantId` | `29b31beb-…6620` | |
| `GraphSub__SecretKeyVaultUri` | your vault URI | **Set the secret's `exp` attribute** — the expiry warning reads it. |
| `GraphSub__TopicNaming` | `Shared` | `PerUser` reproduces the legacy convention. |
| `GraphSub__PartnerTopic` | `GETopicRSEShared` | |
| `GraphSub__ServiceBusQueueResourceId` | …/queues/speventgridqueue | |
| `GraphSub__ChangeTypes` | `Created` | See fact 4. Changing this **replaces every subscription** on the next run. |
| `GraphSub__NotifyTo` / `NotifyFrom` | recipient / sender mailbox | Requires `Mail.Send`. |
| `WEBSITE_TIME_ZONE` | `Pacific Standard Time` | **Required.** See below. |

### The timezone setting is not optional

NCRONTAB is UTC unless the host is told otherwise. Without `WEBSITE_TIME_ZONE` the job runs
at 22:00 UTC — 14:00 or 15:00 Pacific depending on the season. The failure is silent and only
appears at a DST boundary. On a Linux plan use `TZ=America/Los_Angeles` instead.

### Permissions

Already consented on the app: `Mail.Read`, `Mail.ReadBasic.All`, `Mail.ReadWrite`,
`MailboxSettings.Read`, `User.Read.All`, `User.ReadBasic.All`, `Group.ReadWrite.All`,
`Sites.FullControl.All` (SPO).

The archive app deliberately does **not** hold `Mail.Send`. See "Two app registrations" below.

### Two app registrations, and why

| | Archive app | Notifier app |
|---|---|---|
| Name | SharePoint Exchange Event Grid Graph API | RSE GraphSubs Notifier |
| Client id | `43248a7a-1c76-40fd-91b6-57ec5f08639e` | `b227cc3b-dd0c-4306-ae6c-cdef991c41e7` |
| SP object id | `0e6cb350-109d-4b4f-8da1-533fafe83677` | `365b7407-e528-4294-a317-fd4054f79e77` |
| Permissions | Mail.Read, Mail.ReadBasic.All, Mail.ReadWrite, MailboxSettings.Read, User.Read.All, User.ReadBasic.All, Group.ReadWrite.All, Sites.FullControl.All | **Mail.Send only** |
| Used for | everything except the email | the email, nothing else |

**Do not merge them, and do not put an ApplicationAccessPolicy on the archive app.** An
application access policy restricts *every* Exchange permission the app holds — `Mail.Read`,
`Mail.ReadWrite`, `MailboxSettings.Read`, not just `Mail.Send`. The archive app must reach all
~94 mailboxes; scoping it to the sender's group would deny the rest and the next nightly run
would fail to renew or create anything. It would present as a mass permissions outage.

The split exists precisely so the send capability *can* be scoped without touching the archive.
Verified 2026-08-08: the notifier's token carries `Mail.Send` and nothing else, reading a
mailbox returns **403**, and `sendMail` succeeds. `Mail.Send` was then **revoked** from the
archive app.

### Notifier is scoped — applied and verified 2026-08-08

Mail-enabled security group `graphsubs-senders@rse-law.com` (member: `SharePoint@rse-law.com`)
with an Exchange `RestrictAccess` application access policy on the **notifier** app.

Verified four ways, functionally rather than by inspection:

| Check | Result |
|---|---|
| `Test-ApplicationAccessPolicy` — `SharePoint@` | **Granted** |
| `Test-ApplicationAccessPolicy` — `Sullivan@` | **Denied** |
| Notifier `sendMail` as `SharePoint@` | succeeds |
| Notifier `sendMail` as `Sullivan@` | **403** |
| Archive app reads `Sullivan@`, `McComas@`, `SharePoint@` | all OK — policy did not bleed across |

That last row is the one that matters most: it confirms the policy is bound to the notifier app
only. **Never apply one to `43248a7a-…`** — it would restrict that app's `Mail.Read` too and
break subscription management for every mailbox.

To reproduce or extend (EXO PowerShell; `Connect-ExchangeOnline -Device` works non-interactively
enough to paste a code):

```powershell
Connect-ExchangeOnline -Device
New-DistributionGroup -Name "GraphSubs Notification Senders" -Alias graphsubs-senders `
  -Type Security -Members SharePoint@rse-law.com -PrimarySmtpAddress graphsubs-senders@rse-law.com
New-ApplicationAccessPolicy -AppId b227cc3b-dd0c-4306-ae6c-cdef991c41e7 `
  -PolicyScopeGroupId graphsubs-senders@rse-law.com -AccessRight RestrictAccess `
  -Description "Notifier app may only send as the GraphSubs sender mailbox"
```

Adding another sender later means adding it to the group, not editing the policy.

Both secrets belong in the same Key Vault: `GraphSub__SecretName` for the archive app and
`GraphSub__NotifierSecretName` for the notifier. Set the `exp` attribute on both — the nightly
warning currently reads only the archive app's.

The Function App's **managed identity** is separate and needs: `Key Vault Secrets User` on
the vault, and `EventGrid Contributor` (or equivalent) on resource group `Sharepoint1` for
topic activation and event-subscription management.

---

## Replacing subscriptions when their shape changes

`changeType` and `resource` are **immutable** on a Graph subscription — `PATCH` only moves
`expirationDateTime`. So altering either means deleting and recreating all of them.

`MatchesDesiredShape` compares each live subscription against what the engine would create
today, and `MigrateAsync` replaces the ones that differ. Two details that are easy to get
wrong and were deliberate here:

- **The drift check runs before the renew-window skip.** Subscriptions are normally skipped
  when they are not close to expiry. If drift were checked after that, a healthy subscription
  would keep its old shape until it lapsed, and the migration would appear to do nothing for
  days.
- **Delete precedes create.** Creating first would briefly leave two live subscriptions on one
  mailbox, and every event from it would arrive twice. The cost is a gap of a second or two
  per mailbox where new mail raises no event; run migrations outside business hours.

`changeType` is returned lower-cased by Graph and order is not stable, so the comparison is a
case-insensitive set, not a string equality.

Migration of 94 mailboxes took **59 seconds** at `MaxConcurrency=4`.

## Who gets a subscription

Every user that is `accountEnabled`, `userType == Member`, has a `mail` address, and has a
mailbox whose `userPurpose` is in `GraphSub__IncludeMailboxPurposes` (default `user`).

Two groups are deliberately out by default:

- **Accounts with no mailbox** — `mailboxSettings` returns 404. 27 such accounts exist. They
  are reported under `noMailbox`, never under `failed`, so they don't cry wolf nightly.
- **Shared mailboxes** — `3103120656@` (fax), `matters@`, `records@`,
  `mm@meyersmcconnell.com`. Add `shared` to `IncludeMailboxPurposes` to archive them.

`calendar@`, `IT@`, `mtsg@` and `SharePoint@` classify as `user` and **are** included. To
drop any, use `GraphSub__ExcludeGroupId` or `GraphSub__ExcludeUpnPattern` rather than
editing lists by hand.

**Safety rail:** if the roster resolves to zero mailboxes while live subscriptions exist,
the run aborts with a fatal error rather than proceed — that combination means enumeration
broke, and `deleteOrphans` would otherwise wipe live coverage.

---

## Notifications

An email goes to `GraphSub__NotifyTo` on **every** run. The subject carries the outcome
because nobody opens the green ones:

```
[RSE GraphSubs] OK — 96 active, 0 created, 96 renewed
[RSE GraphSubs] 3 FAILED — 96 active, 1 created, 92 renewed
[RSE GraphSubs] SECRET EXPIRES IN 5 DAYS — 96 active, 0 failed
[RSE GraphSubs] FAILED — InvalidOperationException: …
```

It is sent from a `finally` block, so a crash mid-run still reports. A send failure is
logged and swallowed — notification problems must never mask the run's real outcome.

### Credential expiry

Every run reads the Key Vault secret's `ExpiresOn` and warns from 7 days out
(`GraphSub__SecretWarnDays`). A **null** expiry warns too — "unknown" must never read as
"plenty of time". Graph's `/applications` endpoint is deliberately not used; it would need
`Application.Read.All`, a tenant-wide read permission, to learn one date.

Belt and braces: set an expiry on the Key Vault secret so Key Vault emits
`Microsoft.KeyVault.SecretNearExpiry` natively — that fires even if the Function App is dead.

### Dead-man's switch — required

**An email sent by the job cannot tell you the job never ran.** A misfired timer, a stopped
Function App, or a host crash all produce silence, and silence is indistinguishable from a
quiet success. Add an Azure Monitor alert:

- signal: the custom `GraphSubNightly … OK` log event in Application Insights
- condition: **count < 1 over 25 hours**
- action group: email `GraphSub__NotifyTo`

Fire it once deliberately to confirm delivery before relying on it.

---

## Cutover from the Power Automate flow

The flow currently renews from a hardcoded list that was refreshed by hand on 2026-08-08 to
cover all 96 subscriptions. That is a stopgap and it **will** drift again — any recreated
subscription gets a new id, the flow PATCHes a dead GUID, gets a 404, and swallows it. That
is precisely how the original 41-mailbox gap formed.

1. Deploy with the timer **disabled** (`AzureWebJobsDisableFunction.GraphSubNightly = 1`).
2. `POST /api/graphsubs/nightly` (dry run). Confirm the report shows ~96 adopted, the
   expected `noMailbox` count, and **zero** unexpected creates.
3. Run it live once. Confirm the email arrives and `GraphSubStatus` looks sane.
4. Turn **off** the flow's recurrence trigger. Do not run both — two writers PATCHing the
   same subscriptions produce confusing 404s.
5. Enable the timer. Watch two consecutive nightly emails.
6. Only then: delete the old client secret `4795428a-…` and retire the flow.

Keep the flow disabled rather than deleted until step 6 is done — it is the rollback.

### If you keep any Power Automate

Point the flow's `Initialize_variable_strUsersJSON` at `GET /api/graphsubs/users` instead of
a pasted literal. That endpoint returns the identical `arrUsers` envelope from live state, so
the list stops going stale. Store the function key in Key Vault, not inline.

---

## Optional follow-ups

- **Consolidate the remaining 32** subscriptions still on per-user topics
  (`GraphSubReconcile` with a roster of those mailboxes, after deleting each subscription and
  its topic). Cosmetic — both topologies already feed the same queue — and each mailbox takes
  a real delivery gap, so there is no urgency.
- **Delete the ~72 unreferenced per-user topics** once nothing points at them.
- **Dead-lettering.** No event subscription has a dead-letter destination, so a message that
  fails 30 delivery attempts over 24 hours is discarded silently. For a firm archiving mail as
  a record that is a gap; set `GraphSub__DeadLetterContainerResourceId` and the engine wires
  it on every topic it creates.
- **Federated credential instead of a client secret.** It cannot expire, and unlike a managed
  identity it can live on the *same* app registration — so subscription ownership is
  preserved. This removes the whole expiry-warning problem rather than monitoring it.

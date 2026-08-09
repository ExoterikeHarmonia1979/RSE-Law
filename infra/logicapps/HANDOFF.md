# Session handoff — 2026-08-08/09

Everything below was done in one session. Read "Live state right now" first; there is work
in flight.

---

## Live state right now (as of 19:22 local, 2026-08-09 02:22 UTC)

| Thing | State |
|---|---|
| `HTTP-Matter-On-Email-Receipt` | **Enabled**, healthy, 0% failure rate |
| Service Bus `speventgridqueue` | **~2,159 active**, 0 dead-lettered — draining a sweep batch |
| Trigger concurrency | **LIVE = 100, repo file = 40 — this is drift, see below** |
| Inbox sweep | 5,050 of 73,666 enqueued. **Resume with `-Skip 5050`** |
| Unsorted re-file | **Interrupted deliberately.** ~1,381 `.eml` remain in the bucket |
| Git | `main` pushed to `origin/main`, working tree clean |

### Two things to fix first

**1. Concurrency drift.** I raised the live trigger concurrency 40 → 100 to test throughput and
did **not** write it back to `HTTP-Matter-On-Email-Receipt.after.json`. Live and repo disagree.
Decide which is right and make them match — re-running `transform.ps1` will silently revert live
to 40 on the next deploy.

Measured drain was ~147/min at concurrency 40. I had not finished measuring 100 when the session
ended, and the measurement was confounded (see below), so **treat 100 as unvalidated**.

**2. Don't run the sweep and the re-file at the same time.** I did briefly, and it was a mistake
for two reasons:
- both hammer the same Azure Function (`RegExMattersAzFunc`), so they compete;
- the sweep *adds* to `UnsortedMatterCommunication` (tier-3 matches) while the re-file drains it.
  The bucket grew 1,163 → 1,381 while both ran.

**Sweep to completion first, then re-file once.**

---

## Resume commands

```powershell
# az is a per-user ZIP install and is NOT on PATH in Git Bash
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"

# 1. finish the inbox sweep (73,666 total, 5,050 done)
./infra/logicapps/sweep-inbox.ps1 -Max 5000 -Skip 5050 -Execute
# ...repeat, advancing -Skip by the amount queued each time, until scanned >= 73666

# 2. only once the queue is empty, re-file the unsorted bucket
./infra/logicapps/refile-unsorted.ps1 -Max 2000 -Execute

# 3. reconcile the concurrency drift, then redeploy from the repo
./infra/logicapps/transform.ps1 ; ./infra/logicapps/validate.ps1
```

Both scripts are safe to re-run. Blob names are deterministic (matter + sanitised subject), so
reprocessing overwrites rather than duplicates. `refile-unsorted.ps1` copies server-side and
deletes the source only after confirming the destination, so an interrupted run leaves
duplicates, never a loss.

---

## What was changed

### Logic App `HTTP-Matter-On-Email-Receipt` (rg `Sharepoint1`)

SharePoint site/library work removed; blob archiving only. **108 actions → 61; 27 SharePoint
operations → 2 read-only matter lookups.**

Removed: site-exists check, `Create_Microsoft_365_Group`, hub join, folder/file creation, the
whole To/From/Subject/HasAttachments/EmailCreated/AttachmentLinks column+view scaffolding, the
`Update_item*` write-backs, 6 minutes of hardcoded `Delay` actions, and both
move-to-Deleted-Items calls (per request).

The workflow carried **two byte-identical branches** — one for "site exists", one for "site just
created". With SharePoint gone the discriminator went too, so they collapsed to one path. Keeping
all four `Create_blob*` actions, as the original brief asked, would have written every email and
attachment twice.

Correctness fixes found while tracing failures:

- `toUpper(outputs('Get_Email_From'))` threw `InvalidTemplate` on any message with no From. A
  live failure cause, unrelated to SharePoint, that would have survived the removal.
- `For_each_Subject_Word` made one SharePoint lookup **per word of every subject** at concurrency
  20 while mutating shared variables — so `blnKeepProcessing` short-circuited nothing and the
  matter chosen was whichever iteration finished last. Replaced with a single OR'd `$filter`
  query plus a sequential in-memory scan; first matching word in subject order now always wins.
- `AppendTo*Variable` in a parallel loop can **drop** items, not merely reorder them. Those loops
  are now sequential.
- Guarded the blob path against an empty `strFoundMatter`, which wrote to `/matters//Emails/`
  while reporting success.
- Capped blob name length so an oversized subject cannot make an email permanently unarchivable.

Durability: trigger was **auto-complete**, so any failed run silently destroyed that email. Now
peek-lock, work wrapped in a scope, complete on success / abandon on failure. Queue has
`deadLetteringOnMessageExpiration=true`, `lockDuration=PT5M`, `maxDeliveryCount=10`, TTL 14 days.

Auth: Graph calls use the workflow's **managed identity** (`30701da1-0d55-454a-bf67-bfdd70f93a76`,
granted `Mail.Read`). `HTTP_Get_Access_Token` and the Key Vault lookup are gone; no secret in the
definition.

**Unfiled-matter handling (important):** the lookup list is maintained by hand and always lags.
When the lookup returns no row but the function classified the match as `RSE File No`, the email
is now filed under that number anyway. Previously it was archived **nowhere at all** — 87% of all
unfiled mail. Only strict RSE File No values are trusted this way; a Case/Claim number still needs
the list to map it onto a matter.

### Graph subscriptions (`RegExAzFunc`)

`changeType` `Created,Updated` → **`Created`**. 94 subscriptions migrated, 0 failures, 59s.

`Updated` fired on every read, flag and move, and because blob names are deterministic each one
re-downloaded the message and overwrote a blob that was already correct. Measured: **87% of all
queue events were `updated`; 84 archiving runs produced 7 distinct blobs — one email re-archived
44 times.**

`changeType` and `resource` are immutable, so `MatchesDesiredShape`/`MigrateAsync` replace drifted
subscriptions. The drift check runs **before** the renew-window skip on purpose — after it, a
subscription not yet due for renewal keeps the old shape until it lapses and the migration
silently never happens.

Also deleted: orphan subscription `chavez@rse-law.com` (enabled account, but `mailboxSettings`
404s — no mailbox), and the unused `office365` API connection.

### Matter matching (`RegExMattersAzFunc`)

Tokenising keeps `-` because case numbers need it internally
(`30-2023-01351580-CU-PO-NJC`). That meant `100.238- Santa Rosa` tokenised to `100.238-` and the
anchored pattern failed, filing it under `UnsortedMatterCommunication`. Each token is now also
tried with leading/trailing `.`, `-`, `_` stripped — ends only, never the interior.

### Security — a secret was exposed and rotated

While comparing the secret embedded in the Power Automate export against Key Vault, I named a
helper function `H`, which collides with PowerShell's alias for `Get-History`. The function never
ran; both secrets were printed in full in the error output, into the session transcript.

Rotated and closed out:
- new credential on app `43248a7a` (`PEn…`, expires 2028-08-09), verified it reads mail and lists
  subscriptions;
- `GraphSubClientSecret` in `kv-rse-graphsubs` updated;
- Function App restarted, re-read the vault, returned all 94 subscriptions;
- **exposed credential (`2Cg…`) deleted.**

If that transcript is retained anywhere, note the value is already revoked.

---

## The Power Automate flow — deliberately not repaired

`OutlookSearchSPFxWebPart/FIles/UnsortedMattersInbox_20260809014122.zip` is an export of the
**"Unsorted Matters"** flow: 126 actions, 28 SharePoint, 5 blob. Its job was to file mail already
sitting in `matters@rse-law.com` (**73,666 messages back to 2026-02-07**) — a real gap, since the
live pipeline only reacts to new arrivals.

It was not repaired because:
- its embedded client secret is the one **deleted during the incident**, so it could not have
  authenticated anyway;
- Power Automate HTTP actions **cannot use a managed identity**, so fixing it properly means
  adding a Key Vault connection purely to authenticate;
- it cannot be deployed from this machine — no `pac` CLI, and flows are not ARM resources;
- it duplicates matter-matching logic that would drift from the Logic App's.

`sweep-inbox.ps1` replaces it: enumerate the mailbox, raise one Service Bus event per message in
the shape Graph sends, let the hardened pipeline do the filing. Verified on 50 messages — 67 runs,
all succeeded, 28 of 40 sampled archived (70%).

**The flow should be deleted once the sweep is complete**, or it will be a second, broken pipeline.

---

## Results so far

| | Before | After |
|---|---|---|
| Backlog | 924 | 0 |
| Dead-letter queue | 188 | 0 |
| Run failure rate | ~53% | **0%** |
| Actions defined | 108 | 61 |
| SharePoint connector actions | 27 | 2 |
| SharePoint calls per message | 7+, plus one per subject word | **exactly 1** |
| Hardcoded delay per run | 6 min | none |
| Secrets in definitions | 1 plaintext | none |
| Graph event volume | baseline | **−87%** |

Recovered 258 emails behind the original failed runs (578 runs, deduplicated), 100% succeeded.

**No honest before/after run-duration figure exists.** The app was already failing when the
session started, so there was no valid baseline, and the historical successful runs have since
aged out of retention. The structural numbers above are exact.

---

## Gotchas that cost time

- `az` is a per-user ZIP install: `& "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"`. Not on PATH in Git
  Bash.
- `az.cmd` mangles `$top` / `$filter` / `$skiptoken` in ARM URLs — use `Invoke-RestMethod` with a
  bearer token for anything paged.
- ARM tokens expire mid-session. Refresh with
  `az account get-access-token --resource https://management.azure.com`.
- **`filter()` and `select()` are not Logic App expression functions** — they are the `Query` and
  `Select` actions. The designer accepts the expression form and it fails only at runtime.
- An action may only reference another that is on its own `runAfter` path. ARM rejects the whole
  definition otherwise; this is how the first unfiled-matter deploy failed.
- `az storage blob list` silently truncates at 5,000 — a listing that "finds nothing recent" is
  usually truncation, not absence.
- Graph `/subscriptions` pages at ~21 per page. An unpaged count looks like catastrophic loss.
- Don't name a PowerShell function `H` (alias for `Get-History`). That is what leaked the secret.
- Logic App run history is consumed fast under load — recover failed runs *before* a large drain,
  or page deeper (`-MaxPages 80` reached 20,000 runs).

---

## Open items

1. **Finish the sweep** — ~68,600 messages remain.
2. **Then re-file** `UnsortedMatterCommunication` (~1,381 `.eml`).
3. **Reconcile concurrency drift** (live 100 vs repo 40) and validate the right value.
4. **Delete the "Unsorted Matters" Power Automate flow** once the sweep is done.
6. **The matter lookup list is maintained by hand** and lags newly opened matters. The unfiled-
   matter change removes the worst symptom, but a real source of truth would fix the cause.
7. `MimeKit 4.9.0` has a known moderate-severity advisory (surfaced during build).

# Session handoff — 2026-08-09

Second session on the archive pipeline. The previous handoff is superseded; several of its
conclusions were wrong and are corrected below. There is work in flight — read "Live state"
first.

---

## Live state (01:14 local, 08:14 UTC)

| Thing | State |
|---|---|
| `HTTP-Matter-On-Email-Receipt` | **Enabled**, healthy, no drift from baseline |
| Trigger concurrency | **100, live == repo == baseline.** Drift resolved |
| Service Bus `speventgridqueue` | **~47,200 active, 0 dead-lettered**, draining ~200–330/min |
| Inbox sweep | **Enqueue COMPLETE** — all 73,665 messages, 0 send errors |
| Unsorted re-file | **Armed**, fires automatically when the queue empties |
| `UnsortedMatterCommunication` | 2,994 `.eml` and still growing as the sweep files tier-3 misses |
| Power Automate flows | Both dead ones **deleted** |
| Git | `main` at `a488bea`, pushed, tree clean |

Nothing needs doing right now. The queue drains on its own, then the re-file runs on its own.
Roughly 2.5–4 hours of draining remained at the time of writing.

### The one thing to know before touching a deploy

Use `./deploy.ps1`, never a hand-rolled PUT, and let it check drift. Two ways to lose work by
hand: omitting `identity` strips the managed identity every Graph call uses, and a PUT is a
full replace, so it silently reverts any live change the repo does not know about.

---

## Corrections to the previous handoff

**"0% failure rate" was true when written but went stale within minutes.** Failures had
resumed. Two were real bugs, below.

**"Concurrency 100 is unvalidated — treat as unproven" — it is now validated, at ~330/min
versus ~147 at 40.** It is in the repo, live, and baselined.

**Do not measure throughput by counting runs in the run history.** It undercounts badly under
load — it gave 140/min while the queue was genuinely draining at ~330/min. Queue depth is the
trustworthy signal. Mid-session I "corrected" 330 down to 140 and that correction was wrong.

**ARM's Service Bus counters are cached and lag.** Consecutive 3-minute samples read 1177, 999,
577 then 9/min while nothing was wrong. A single reading proves nothing; a clean 60-second
sample showed 197/min. Do not diagnose a stall from one sample — I raised a false alarm doing
exactly that.

**Power Automate flows *can* be managed from this machine.** The old handoff said they could
not without `pac`. `pac` is genuinely absent, but the REST API at `api.flow.microsoft.com`
accepts an `az` token for the `service.flow.microsoft.com` audience. Both flows were deleted
that way.

**`before.json` is not a stale cache to be refreshed — it is a frozen record of the original.**
`before.json` + `transform.ps1` together are the source of truth: the original, plus every
intentional change as reviewable code. Recapturing it from live would collapse the two and
discard the rationale, *and* it does not work — `transform.ps1` reaches for
`$root.If_Odata_ID_is_valid`, which is top-level in the original but nested inside
`Process_Message` in the current shape, so it dies partway through after mutating other parts.
This was attempted and reverted; don't repeat it.

---

## What changed this session

Six commits, `81849b1..a488bea`.

### Two live bugs that were destroying mail

**A tab in the subject made an email permanently unarchivable.** `Create_blob_1` returned
`400 InvalidUri`. Because the blob name is deterministic, the message failed *identically* on
all 10 redeliveries and dead-lettered unarchived — silent loss. Real subjects carry tabs when
a forwarded header block is pasted into the subject line. `San()` stripped only the
Windows-illegal filename set.

Now the full C0 range plus DEL is stripped, not just the tab/CR/LF actually observed, since a
vertical tab or form feed fails the same way. Verified end-to-end: the two dead-lettered
messages replayed and both succeeded, producing a 453 KB blob under `100.077`.

**A stale `state` in the deploy file disabled production.** `after.json` carried
`state: Disabled`, captured while the workflow was disabled, and a PUT is a full replace — so
deploying from the generated file disabled the live workflow. I hit this, and re-enabled within
about a minute against an empty queue, so nothing was missed. `transform.ps1` now forces
`state = 'Enabled'` on emit. Any redeploy from that file would have done the same.

### Drift can no longer be silent

The concurrency 100-vs-40 split existed because a portal change lived nowhere in the repo and
nothing compared the two.

`deploy.ps1` keeps `deployed.json` — the definition as the tooling last PUT it — and compares
live against **that baseline**, not against the new definition. Comparing forwards detects
nothing, because every intentional change is also a difference. On drift it names the paths and
refuses, unless `-AcceptDrift`. `transform.ps1` runs the same check before overwriting
`after.json`, refusing *before* it writes; by the time `deploy.ps1` blocks the PUT the file
already disagrees with live and the reason is easy to miss. Shared logic is in `drift.ps1` —
one copy, so the two cannot disagree.

`deployed.json` is committed deliberately: a baseline only one machine knows about cannot tell
you someone else edited the portal.

**`after.json` is now emitted key-sorted.** `ConvertFrom-Json -AsHashtable` returns unordered
hashtables, so regeneration reshuffled keys and produced ~538 changed lines for a one-line
edit. That is not tidiness — a real change is unreviewable in that much noise, which is
plausibly how the concurrency difference survived review.

### Both dead Power Automate flows deleted

| Flow | Actions | Why safe |
|---|---|---|
| Unsorted Matters | 126 | `Request`-triggered so it never fired on a schedule; last run 7/30; replaced by `sweep-inbox.ps1` |
| HTTP Matter On Email Receipt | 74 | Stopped since April, no runs in retained history; the Logic App's ancestor |

**Correction (2026-08-15):** an earlier note here and in commit `2a884e6` said the Unsorted
Matters export zip was "already in the repo". It is not. `OutlookSearchSPFxWebPart/.gitignore`
ignores `FIles/` wholesale, so the zip exists only on this machine and is not a durable backup —
if the machine is lost, that flow definition is gone. It was not committed after the fact on
purpose: the export embeds the `AJz` client secret, GitHub push protection would reject it, and
the flow is fully superseded by `sweep-inbox.ps1`. Recorded so nobody counts on a backup that
does not exist.

The second flow had no export anywhere, so its definition is committed at
`powerautomate-HTTP-Matter-On-Email-Receipt.deleted-20260809.json`. Worth keeping for the
trigger alone: `When_a_message_is_received_in_a_queue_(auto-complete)` — the pattern that
destroyed an email outright whenever a run failed, which the peek-lock rework replaced.

`Sched Renew Graph API Subscription` remains (Stopped, has an export zip).

### A second exposed secret, already dead

GitHub push protection rejected the captured flow definition: it had a client secret for app
`43248a7a` inline in an `HTTP_Get_Access_Token` body, hint `AJz` — neither the `2Cg` revoked
last session nor its `PEn` replacement. The app now has exactly one credential (`PEn`, expires
2028-08-09), so `AJz` was already revoked: nothing to rotate, and it explains why the flow
could not have authenticated. The value never reached the remote — the push was rejected and
the commit amended, not bypassed. Redacted in the committed copy.

---

## The unsorted bucket will not empty, and that is not a bug

Sampling 123 subjects spread across all candidates:

| Matcher verdict | Share | Re-filable |
|---|---|---|
| `Unsorted` — no matter named in the subject at all | **80.5%** | No |
| `Case/Claim No` | 13% | No — needs the lookup list to map onto a matter |
| `RSE File No` | **6.5%** | **Yes** |

So expect the re-file to move roughly 1 in 15 and leave the bucket ~93% full. Four in five of
these subjects contain nothing a matcher could resolve. **The hand-maintained lookup list is
the binding constraint on the rest** — that open item is the main remaining lever, not a
nice-to-have.

Two groups the re-file will never touch, both pre-sanitiser artifacts where a `/` in the
subject created a pseudo-directory:

- **8 nested `.eml`** at paths like `07.020:  cmc on 7/9?.eml`, `119.010/119.015/119.019.eml`.
  The top-level filter (which exists to avoid `Attachments/`) skips them.
- **13 zero-byte pseudo-directory entries.**

---

## Resume commands

```powershell
# az is a per-user ZIP install and is NOT on PATH in Git Bash
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"

# the sweep is finished - do not re-run it unless you mean to reprocess the whole mailbox
# (safe, but ~73,665 messages of work; blob names are deterministic so it overwrites)

# re-file, if the armed background job did not run
./infra/logicapps/refile-unsorted.ps1 -Max 5000 -Execute     # loop until moved=0

# definition work
./infra/logicapps/transform.ps1    # refuses if live has drifted
./infra/logicapps/validate.ps1     # must print ALL CHECKS PASSED
./infra/logicapps/deploy.ps1       # dry run; add -Execute to deploy
```

---

## Gotchas

Still true from last session: `az` is at `$env:LOCALAPPDATA\AzureCLI\bin\az.cmd`; `az.cmd`
mangles `$top`/`$filter`/`$skiptoken` in ARM URLs, so page with `Invoke-RestMethod`; ARM tokens
expire mid-session; `filter()`/`select()` are Logic App *actions*, not expression functions; an
action may only reference another on its own `runAfter` path; Graph `/subscriptions` pages at
~21; never name a PowerShell function `H`.

New:

- **`az storage blob list` silently truncates.** `--num-results 5000` hid blobs past the cap
  no matter how often the script re-ran. `--num-results '*'` returns every page — verified
  against a REST listing, both 4,126.
- **`az` mangles non-cp1252 blob names.** "Unable to encode the output with cp1252 encoding.
  Unsupported characters are discarded" — emoji, curly quotes, CJK. 5 of 2,380 when measured.
  The loss happens inside `az` before PowerShell sees it, so neither `[Console]::OutputEncoding`
  nor `PYTHONIOENCODING` helps; only listing over REST avoids it. Those blobs fail safe: the
  copy 404s and the source is left in place.
- **Never recurse through `ForEach-Object` when transforming JSON.** The pipeline passes a
  PSObject-wrapped element, and a wrapped string satisfies `-is [pscustomobject]` where a bare
  one does not — so `"Succeeded"` became `{"Length":9}`, rewriting every `runAfter` status and
  schema `required` list. Test scalars first, walk arrays with `foreach`. A byte-stability
  assertion caught this; `validate.ps1` did not.
- **Service Bus `lockDuration` caps at `PT5M`** and cannot be raised. At concurrency 100 about
  1.2% of runs exceed it and lose the lock *after* archiving succeeded; the message redelivers
  and rewrites the same deterministic blob. Repeated work, not lost mail.
- **A `[xml]` cast fails on Azure REST responses** because of the UTF-8 BOM. Strip it first.
- **Background jobs need `run_in_background`, not `Start-Job`** — shell state does not survive
  between calls, so the job dies with its shell.
- **`sweep-inbox.ps1 -Skip` re-walks the mailbox from the start** each run, so later offsets
  spend longer paging Graph before enqueueing anything. Larger `-Max` reduces that.

---

## Open items

1. **Wait for the queue to drain, then confirm the re-file ran.** Both are automatic.
2. **The lookup list is maintained by hand and lags newly opened matters.** Now known to gate
   ~93% of the unsorted bucket. A real source of truth is the highest-value remaining fix.
3. **8 nested `.eml` + 13 zero-byte entries** stranded in `UnsortedMatterCommunication`.
4. **`MimeKit 4.9.0`** has a known moderate-severity advisory.
5. **Consider deleting `Sched Renew Graph API Subscription`** — stopped, superseded by
   `RegExAzFunc`, and a stopped-but-present flow is what someone restarts by accident later.
6. **No honest before/after run-duration figure exists.** The app was already failing when the
   first session started, so there is no valid baseline, and the historical successful runs
   have aged out of retention. Structural numbers are exact; duration ones do not exist.

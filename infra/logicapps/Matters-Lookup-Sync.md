# Matters-Lookup-Sync

Keeps the `Matters Lookup` list fed from the matter intake spreadsheet, so the archive can
resolve a matter from an email subject. This is the automation for open item #2 in
`HANDOFF.md`: that list was maintained entirely by hand, and it gates roughly 93% of the
unsorted email bucket.

| | |
|---|---|
| Resource group | `Sharepoint1` (eastus), subscription `66268ff4-…` |
| Managed identity | `02c28fc9-84a6-4d2e-955e-53834fd20c33` — `Sites.Selected`, granted **read on the `RSEFirmResources` site only** |
| Source | `LIST26.xlsx`, table `List26`, in the **Admin** library of `RSEFirmResources`, folder `/LISTS` |
| Target | SharePoint list `940d4826-…` on `MatterExchange-POC` — the same list the archive reads |
| Trigger | Recurrence, every 15 minutes |
| Connection | reuses `sharepointonline`, shared with the archive workflow |

## Working on it

```powershell
./validate-matters-lookup-sync.ps1     # must print ALL CHECKS PASSED
./deploy.ps1 -Workflow Matters-Lookup-Sync `
             -DefPath ./Matters-Lookup-Sync.json `
             -BaselinePath ./Matters-Lookup-Sync.deployed.json            # dry run
./deploy.ps1 -Execute -Workflow Matters-Lookup-Sync `
             -DefPath ./Matters-Lookup-Sync.json `
             -BaselinePath ./Matters-Lookup-Sync.deployed.json
```

Unlike the archive workflow there is no `before.json`/`transform.ps1` pair. That indirection
exists there because the definition was inherited and every change had to stay reviewable
against the original. This one was written from nothing, so the JSON *is* the source and is
edited directly. Everything else is the same: `deploy.ps1` still refuses to PUT over an
out-of-band portal edit, and `Matters-Lookup-Sync.deployed.json` is committed as the shared
baseline for exactly the reason described in `README.md`.

**To dry-run against production safely, set `maxWritesPerRun` to `0` and deploy that.**
Every count in the run summary is still computed; `take(x, 0)` empties both batches so no
write happens. That is how this was commissioned, and it is the right way to check a change
before letting it write.

## What it does

```
Recurrence (15 min)
├ Get_workbook_columns          Graph workbook API, managed identity
├ Get_existing_list_items       all 1,300+ rows, paginated
└ Check_inputs  ── else ──►     Terminate Failed
    │   guard: both columns resolved AND the list read returned > 0 items
    ├ pair 'RSE File #' with 'Claim Number' by row index, trimming both
    ├ drop blank file numbers, de-duplicate by file number
    ├ create : sheet file numbers absent from the list
    └ update : ONLY where the list's ClaimNo is blank
```

Both loops iterate a batch capped at `maxWritesPerRun` (250). Anything over the cap is
reported as `createBacklog` / `updateBacklog` and picked up next run.

The run summary is the output of `Compose_run_summary` — read it rather than counting
actions:

```
created  updated  createBacklog  updateBacklog  claimConflictsLeftAlone
existingListItems  sheetDataRows  validSheetRows  distinctSheetFiles
```

## Things that will bite you

**It will never overwrite a claim number somebody typed in, and that is deliberate.** When
this was commissioned, 196 sheet rows disagreed with the list. Only 25 were blanks to fill.
In the other 171 the list already held a different value — and in 117 of those, the list's
`ClaimNo` held the **court case number** while `CaseNo` held the insurer claim, i.e. the two
columns are reversed relative to what the spreadsheet means by them. Overwriting would have
deleted 171 tokens the archive matches subjects against, degrading the exact lookup this
workflow exists to improve. The count is reported every run as `claimConflictsLeftAlone`; it
needs a human decision, not a rule.

**Nothing is ever deleted.** A row removed from the spreadsheet leaves its list item in
place. Old matters still receive email, and the archive needs the row to file it.

**The zero-items guard is load-bearing.** If the list read ever returns 0 items, every sheet
row looks missing and the create loop would duplicate the entire list. `Check_inputs` fails
the run instead. It fires on a renamed spreadsheet column too — `RSE File #` and
`Claim Number` are matched by name, so a rename stops the sync loudly rather than silently
syncing nothing.

**The workbook is addressed by drive id + item id, not by path.** Path addressing
(`/root:/LISTS/LIST26.xlsx:/workbook/...`) fails consistently with
`AccessDenied — Could not obtain a WAC access token`, while item-id addressing works. The
cost is that deleting and re-uploading the file mints a new item id and the run 404s; fix
`workbookItemId`. Renaming or moving the file is fine.

**The file lives in the `Admin` library, not `Documents`.** `/sites/{id}/drive` is the wrong
drive and 404s. That is why `workbookDriveId` is pinned.

**`Sites.Selected` cannot go finer than a site.** The identity can read every library in
`RSEFirmResources`, not just this one workbook. That is still far narrower than the
`Files.Read.All` alternative, which would have granted read across the whole tenant.

**Writes are the SharePoint connector, reads are Graph.** Deliberate: the write side reuses
the connection the archive already depends on, so no second SharePoint credential exists to
expire. It does mean writes run as `SharePoint@rse-law.com`.

## Working the conflicts

`claimConflictsLeftAlone` is a number in a run summary; `export-conflicts.ps1` turns it
into something a person can act on.

```powershell
./export-conflicts.ps1                              # dated .xlsx in the current directory
./export-conflicts.ps1 -OutFile C:\some\where.xlsx
```

Two sheets: a summary explaining what the rows are, and every conflict with a frozen
header and autofilter, sorted into categories — `Columns reversed` (the sheet value is
already in `CaseNo`), `Suffix drift`, `CaseNo blank`, `Conflicting values` — each with a
suggested action and a link straight to the list row. Deciding a whole category at once is
faster than going matter by matter.

**The output holds client names and matter numbers. Do not commit it.** The last one went
to `OutlookSearchSPFxWebPart/FIles/`, which `.gitignore` already excludes.

Re-run it as the list changes; it reads both sides live and holds no state.

Two things in that script look roundabout and are not, both documented in its header: it
reads the list through a throwaway Logic App (the interactive `az` sign-in gets 403 on this
list — no `Sites.*` scope — while the `sharepointonline` connection reads it fine), and it
writes the `.xlsx` as OOXML by hand (Excel COM is installed on this machine but
non-functional: `Workbooks.Add()` returns null, so Excel cannot create a file at all).

## Recovery

Re-running is always safe — it computes what is missing from live state each time and holds
no cursor. A run that fails partway leaves the items it already created; the next run creates
the remainder.

If a backlog is being worked off, trigger runs rather than waiting 15 minutes each:

```powershell
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$tok = (& $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
Invoke-RestMethod -Method Post -Headers @{Authorization="Bearer $tok"} `
  -Uri "https://management.azure.com/subscriptions/66268ff4-4804-4950-bfba-07b41a8660ec/resourceGroups/Sharepoint1/providers/Microsoft.Logic/workflows/Matters-Lookup-Sync/triggers/Recurrence/run?api-version=2016-06-01"
```

## Commissioning result — 2026-08-19

Backfill from an empty starting point, verified by dumping the list before and after:

| | |
|---|---|
| Items created | 273 (list 1,045 → 1,318) |
| Blank claim numbers filled | 25 |
| Non-blank claim numbers overwritten | **0** |
| `CaseNo` / `RSEFileNo` altered on existing rows | **0** |
| Sheet file numbers still missing afterwards | **0** of 517 |
| New duplicate file numbers | 0 (the one pre-existing duplicate, `06.256`, is untouched) |
| Third consecutive run | 0 creates, 0 updates — idempotent |

Known data issues found while commissioning, none of them this workflow's to fix:

- **171 claim-number conflicts**, described above.
- **`113.01` in the sheet against `113.001` in the list** — almost certainly a typo. It was
  created as its own row rather than silently dropped or silently merged.
- **3 list items have a blank `RSEFileNo`** and 1 file number (`06.256`) appears twice. Both
  pre-date this workflow.

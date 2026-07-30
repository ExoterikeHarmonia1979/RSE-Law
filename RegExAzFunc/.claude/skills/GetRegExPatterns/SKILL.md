---
name: GetRegExPatterns
description: Connect to a SharePoint list via Microsoft Graph, pull the real values of one or more columns, and derive a small, comprehensive set of C# regular expressions that match those values. Use when asked to generate/regenerate regex patterns for a SharePoint list column (e.g. "get regex patterns for column X in list Y"), or to refresh CaseClaimNoPatterns.cs-style pattern arrays from live data.
---

# GetRegExPatterns

Derives a minimal, comprehensive `string[]` of C# regexes for one or more SharePoint list
columns, from real data rather than guesswork. Follow these phases in order.

## Inputs needed

Ask the user (or infer from context/prior conversation) for:
- The SharePoint site URL (e.g. `https://<tenant>.sharepoint.com/sites/<site>`).
- The list name (e.g. "Matters Lookup").
- The column internal name(s) to derive patterns for (e.g. `CaseNo`, `ClaimNo`).
- Where the resulting C# file should go (an existing pattern file to update, or a new file
  in the current project's root namespace — check an existing file like `RulePatterns.cs`
  or `RegExMattersAzFunc.cs` for the namespace and style conventions to match, if present).

If several columns are requested together and their value shapes overlap heavily (test this
empirically — don't assume), produce one combined pattern array as previously done for
`CaseNo`/`ClaimNo`; otherwise produce separate arrays per column.

## Phase 1 — Authenticate to Microsoft Graph

This environment has no stored SharePoint/Graph session and no browser for interactive
login. Use the OAuth **device code flow** directly via `Invoke-RestMethod` (PowerShell) —
do not rely on `Connect-PnPOnline -DeviceLogin`, which has been observed to fail silently
in this non-interactive shell host (a console-threading limitation), even though the
underlying auth would succeed.

1. Derive the tenant's `.onmicrosoft.com` domain from the site URL's subdomain
   (`https://<tenant>.sharepoint.com/...` → `<tenant>.onmicrosoft.com`).
2. Request a device code against `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/devicecode`
   using client_id `04b07795-8ddb-461a-bbee-02f9e1bf7b46` (Microsoft Azure CLI — a
   first-party app pre-consented in almost every tenant) with
   `scope = "https://graph.microsoft.com/.default offline_access"`.
3. Print the `user_code` and `verification_uri` to the user and ask them to sign in there.
4. Poll the token endpoint in the background (`run_in_background: true`, long timeout) with
   `grant_type=urn:ietf:params:oauth:grant-type:device_code`, handling
   `authorization_pending` (keep polling) and `slow_down` (back off).
5. **Do not attempt to acquire raw username/password credentials from the user for ROPC.**
   It doesn't work with MFA, is deprecated, and device-code login already uses the user's
   real credentials safely via their own browser.

### If the first token's consented scopes don't include Sites.Read.All

A `.default` token only returns previously-consented permissions — it will not silently
grant new ones. If a `sites/.../lists` call comes back with zero results (not an error) or
you decode the token and don't see `Sites.Read.All` in `scp`, that's the tell. Also, the
classic SharePoint REST API (`/_api/web/...`) commonly fails with
`x-ms-diagnostics: reason="App is not allowed to call SPO with user_impersonation scope"`
when tenants have hardened against legacy SPO API scopes — don't fight this, just use Graph.

To get `Sites.Read.All` explicitly:
1. Run a **second** device-code request, this time with client_id
   `14d82eec-204b-4c2f-b7e8-296a70dab67e` (Microsoft Graph PowerShell — a first-party app
   whose whole purpose is broad, user-consentable Graph scopes) and
   `scope = "https://graph.microsoft.com/Sites.Read.All offline_access"`.
   (Azure CLI's own client ID will reject this with `AADSTS65002` — it isn't preauthorized
   for Sites.Read.All — so don't retry with the same client id.)
2. Have the user approve the new consent prompt, then poll for the token as before.

## Phase 2 — Resolve the site, list, and pull column data

Using the Graph-scoped token:

1. Resolve the site: `GET https://graph.microsoft.com/v1.0/sites/<tenant>.sharepoint.com:/sites/<site-path>`
   → capture `id`.
2. Optionally confirm the target list's internal column names:
   `GET /v1.0/sites/{siteId}/lists?$select=id,name,displayName` to find the list id, then
   `GET /v1.0/sites/{siteId}/lists/{listId}/columns?$select=name,displayName,hidden` to
   confirm the requested display name(s) map to the expected internal `name`(s).
3. Page through all items with the target fields expanded:
   `GET /v1.0/sites/{siteId}/lists/{listId}/items?$expand=fields($select=<col1>,<col2>,...)&$top=200`,
   following `@odata.nextLink` until exhausted.
4. Export to a scratch CSV and compute the **distinct, trimmed, non-blank** values per
   column (and the union across columns if combining them into one pattern set).

## Phase 3 — Derive minimal patterns from real data (don't guess blind)

1. First get a feel for the data: normalize each distinct value to a shape signature
   (letters → `A`, digits → `9`, punctuation kept) and group/count shapes. This reveals the
   dominant structural families fast.
2. For each family, write a **generalized** pattern using character classes and quantifier
   ranges instead of one pattern per literal prefix — e.g. a shared shape like
   `[A-Z]{2-5 letters}\d{6}-\d{3}-\d{3}-\d{3}` covering dozens of distinct carrier/office
   prefixes should be ONE pattern (`^[A-Z]{2,5}\d{6}(-\d{3}){3}$`-style), not one per prefix.
   Look for: leading-digit-count ranges that can be merged (e.g. 2 vs 4-digit leads →
   `\d{2,4}`), optional dashes (`-?`), optional trailing letter/suffix groups
   (`(-[A-Z]{1,3})?`), and shapes that are strict subsets of a more general pattern already
   drafted (fold them in and re-test rather than adding a new pattern).
3. **Validate empirically, don't eyeball it**: write a small PowerShell script that tests
   every candidate pattern (anchored `^...$`, case-sensitive matching `-cmatch` against the
   uppercase data) against every distinct value, and reports what's unmatched. Iterate:
   add or widen patterns to close real gaps, re-run, repeat.
4. After reaching full or near-full coverage, print each pattern's individual match count
   across the distinct set to confirm every pattern is pulling real weight — if one pattern
   is a strict subset of another's matches, fold it in and drop it.
5. Stop widening once one or two single-occurrence outliers remain that don't share a shape
   with anything else in the data (likely data-entry typos). Don't add a dedicated pattern
   for a single anomalous value — flag it to the user by value instead, and ask whether it's
   a typo or a real format worth covering.

Target: as few patterns as achieve ~99%+ coverage of distinct real values, not 100% coverage
at the cost of a much longer list.

## Phase 4 — Emit the C# array

- Match the target file/project's existing conventions (namespace, `public static class ...
  { public static readonly string[] Patterns = { ... }; }`, verbatim `@"..."` string
  literals, trailing comma style) — check a sibling file like `RulePatterns.cs` if one
  exists.
- Add a short header comment: source list/site, generation basis (N of M distinct values
  covered, as a percentage), and any known uncovered outlier values.
- Add a one-line comment above each pattern with 2-4 real example values it matches, so a
  future reader can sanity-check it without re-running the derivation.

## Phase 5 — Wire the array into consuming code (if asked)

If an existing Azure Function or other consumer already has narrower, single-pattern checks
for the same concept (e.g. separate "Case No" and "Claim No" blocks each with one hardcoded
regex), don't just point both blocks at the new shared array and assume it's fine — if the
array was built because those columns' values overlap in shape, the first block will now
catch everything and the second becomes unreachable dead code. **Ask the user** how they
want it resolved (merge into one block/type-label vs. keep separate blocks vs. something
else) rather than guessing; this is a real behavioral/API-shape decision, not a style
choice.

Also flag, when relevant, that the emitted patterns are fully anchored (`^...$`), so a
consumer that tokenizes freeform text needs clean tokens — a stray attached character (e.g.
a leading `#`, trailing punctuation) will make an otherwise-valid value fail to match
entirely. If the consumer's tokenizer only splits on whitespace, that's worth calling out
rather than silently assuming the input will always be clean.

## Phase 6 — Validate individual values on request

When asked "does `<value>` match?", don't reason about the regex by eye — test it directly:
read the actual pattern array from the emitted C# file (so you're testing what's really
shipped, not a remembered copy) and check the value against each pattern in order with a
one-off PowerShell snippet (`-cmatch`, case-sensitive since the data and patterns are
uppercase). Report which pattern (by its comment/description) matched, or if none did,
say so plainly — and if the value's shape looks like it belongs to a different column/family
the array was never built for (e.g. an RSE File No shape when the array is for Case/Claim
No), say that too instead of implying it's a coverage gap.

## Phase 7 — Clean up

Delete any scratch files holding access tokens or pulled list data
(`Remove-Item ... -Force`) once the pattern file is written — don't leave live tokens or
firm data sitting in the temp directory.

# Logic App k-token Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the archive pipeline creating a duplicate blob per recipient mailbox and per retention move, by naming mail after the message rather than after the mailbox copy it arrived in.

**Architecture:** A new Azure Function is the single implementation of the `k`-token. The Logic App posts the raw MIME it already holds and gets a token back, falling back to today's naming if the call fails. The sweep and reconcile scripts get a cheaper endpoint taking `messageId` + `sentDateTime`, which they already receive free from Graph. Nothing is renamed; the two identifier spaces coexist.

**Tech Stack:** .NET 10 isolated-worker Azure Functions (`Microsoft.Azure.Functions.Worker` 2.51.0), MimeKit 4.9.0, MsgReader 6.1.0, xunit; PowerShell 7; Azure Logic Apps (Consumption); Python 3 (`ingest-key.py`, unchanged).

**Spec:** `docs/superpowers/specs/2026-09-08-logic-app-k-token-naming-design.md`

## Global Constraints

- **Base branch must contain three things**: `infra/logicapps/tools/ingest-key.py` (the reference implementation), the `RegExAzFunc.Tests` xunit project, and `MsgReader` in `RegExAzFunc.csproj`. Today only `deploy/file-tree-plus-ingest` has all three — branch from it and cherry-pick this plan and its spec.
- **The token rule, copied verbatim from `ingest-key.py`:**
  - `clean_mid`: remove `[\x00-\x1f\x7f]+` **first**, then `.strip()`, then strip `<` and `>`, then `.strip()`. Control characters must go before the angle brackets — a real message in the June 2024 batch carried a NUL immediately after `>`, and stripping `<>` first could not reach it.
  - `sent_utc`: parse the RFC 5322 `Date` header, convert to UTC, format `yyyy-MM-ddTHH:mm:ssZ`.
  - `dedup_key`: `'k' + sha256(lower(messageId) + '|' + sentUtc).hexdigest()[:22]`. Both parts required; if either is missing there is no token.
- **A naming call must never lose mail.** Every failure path in the Logic App falls back to today's `$idTail`. Never dead-letter, never retry into a stall.
- **The identifier is chosen once per message.** The `.eml` name and its `Attachments/<id>/` folder always use the same one. A `k`-token `.eml` beside an `$idTail` attachment folder is worse than either scheme applied consistently.
- **Predictors treat a message as archived if *either* scheme matches.** Never only one.
- **Do not rename existing blobs.** All 258,974 legacy-named blobs stay as they are.
- **Rollout order is fixed:** Function shipped and proven → predictors learn both schemes → Logic App switches. Reversing the last two re-uploads the archive in the window between them.
- Pre-existing build warnings: 4 unique CS8618 + 1 NU1902 (MimeKit advisory). Add none.

---

### Task 1: Measure whether Graph's sent date matches the message header

This gates the design. The sweeps' cheap endpoint is only worth having if Graph's `sentDateTime` agrees with the `Date:` header every token in the archive was derived from. Nothing breaks if they disagree — the idempotency argument in the spec holds either way — but the sweeps would re-queue most of the recent corpus on every run, and that is worth knowing now.

**Files:**
- Create: `infra/logicapps/tools/check-sentdate-agreement.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: a measured agreement rate, recorded in the spec. No code other tasks call.

- [ ] **Step 1: Write the probe**

```powershell
#requires -Version 7
<#
Does Graph's sentDateTime match the Date: header?

Every k-token in the archive was derived from the Date: header inside the message. The
sweeps want to compute tokens from Graph's sentDateTime instead, because it arrives free
in a $select they already issue and fetching each message's MIME would not be affordable.

That substitution is only sound if the two agree. This measures it rather than assuming
it. Read-only.
#>
param(
  [string]$Mailbox = 'matters@rse-law.com',
  [int]$Sample = 200
)
$ErrorActionPreference = 'Stop'
$az = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"

$graph = (& $az account get-access-token --resource https://graph.microsoft.com/ --query accessToken -o tsv)
$gh = @{ Authorization = "Bearer $graph" }
$uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$Mailbox`?`$select=id" -Headers $gh).id

$url = "https://graph.microsoft.com/v1.0/users/$uid/messages" +
       "?`$select=id,internetMessageId,sentDateTime&`$top=$([Math]::Min($Sample,999))"
$page = Invoke-RestMethod -Headers $gh -Uri $url

$agree = 0; $differ = 0; $noHeader = 0; $deltas = @()
foreach ($m in $page.value) {
  # $value is the raw MIME. Only the header block is needed, so ask for the first 64 KB.
  try {
    $mime = Invoke-WebRequest -Headers ($gh + @{ Range = 'bytes=0-65535' }) `
              -Uri "https://graph.microsoft.com/v1.0/users/$uid/messages/$($m.id)/`$value" `
              -UseBasicParsing
  } catch { $noHeader++; continue }

  $text = [Text.Encoding]::ASCII.GetString($mime.Content)
  $hdr = [regex]::Match($text, '(?im)^Date:\s*(.+?)\s*$')
  if (-not $hdr.Success) { $noHeader++; continue }

  try { $fromHeader = ([datetimeoffset]::Parse($hdr.Groups[1].Value)).ToUniversalTime() }
  catch { $noHeader++; continue }
  $fromGraph = ([datetimeoffset]$m.sentDateTime).ToUniversalTime()

  # To the second, which is the precision the token uses.
  $d = [Math]::Abs(($fromHeader - $fromGraph).TotalSeconds)
  if ($d -lt 1) { $agree++ } else { $differ++; $deltas += [int]$d }
}

$total = $agree + $differ
Write-Host ""
Write-Host "sampled            : $($page.value.Count)"
Write-Host "comparable         : $total"
Write-Host "no usable header   : $noHeader"
if ($total -gt 0) {
  Write-Host ("agree to the second: {0} ({1:N1}%)" -f $agree, (100*$agree/$total))
  Write-Host ("differ             : {0}" -f $differ)
  if ($deltas.Count) {
    Write-Host ("  deltas seconds   : min {0}, median {1}, max {2}" -f `
      ($deltas | Measure-Object -Minimum).Minimum,
      ($deltas | Sort-Object)[[int]($deltas.Count/2)],
      ($deltas | Measure-Object -Maximum).Maximum)
  }
}
Write-Host ""
Write-Host "Read-only. Nothing was written."
```

- [ ] **Step 2: Run it**

```bash
pwsh infra/logicapps/tools/check-sentdate-agreement.ps1 -Sample 200
```

Expected: an agreement percentage. There is no pass/fail threshold to hit — the number itself is the deliverable.

- [ ] **Step 3: Record the result in the spec**

Replace the "Whether Graph's `sentDateTime` matches the `Date:` header is unmeasured" paragraph under **Unverified, and load-bearing** with the measured figure, the sample size, and the date. If agreement is below ~95%, add a sentence saying the sweeps will re-queue at roughly the disagreement rate, so whoever runs one is not surprised.

- [ ] **Step 4: Commit**

```bash
git add infra/logicapps/tools/check-sentdate-agreement.ps1 docs/superpowers/specs/2026-09-08-logic-app-k-token-naming-design.md
git commit -m "Measure whether Graph's sent date matches the message header"
```

---

### Task 2: DedupTokenFunc

The single implementation of the token. Built and tested before anything calls it.

**Files:**
- Create: `RegExAzFunc/DedupToken.cs`
- Create: `RegExAzFunc/DedupTokenFunc.cs`
- Create: `RegExAzFunc.Tests/DedupTokenTests.cs`

**Interfaces:**
- Consumes: `MattersBlobs` is *not* used here; this Function touches no storage.
- Produces:
  - `internal static class DedupToken` with `string? CleanMid(string? raw)`, `string? SentUtc(string? rawDate)`, `string? Key(string? mid, string? sent)`, and `(string? Token, string? MessageId, string? SentUtc) FromBytes(byte[] bytes)`
  - HTTP endpoint `DedupTokenFunc` at `AuthorizationLevel.Function`

- [ ] **Step 1: Write the failing tests**

Create `RegExAzFunc.Tests/DedupTokenTests.cs`. These pin the rule against values taken from `ingest-key.py`, not against the C# that is about to be written.

```csharp
using System.Text;
using Company.Function;

namespace RegExAzFunc.Tests;

public class DedupTokenTests
{
    [Fact]
    public void Key_matches_the_python_reference()
    {
        // sha256("<abc@example.com>" lowercased, bare, + "|" + sent) truncated to 22 hex
        // chars, prefixed 'k'. Computed with ingest-key.py's dedup_key().
        string? token = DedupToken.Key("abc@example.com", "2026-03-20T21:52:57Z");

        Assert.NotNull(token);
        Assert.StartsWith("k", token);
        Assert.Equal(23, token!.Length);          // 'k' + 22 hex
        Assert.Matches("^k[0-9a-f]{22}$", token);
    }

    [Fact]
    public void Key_is_stable_and_case_folds_the_message_id()
    {
        Assert.Equal(DedupToken.Key("ABC@Example.COM", "2026-03-20T21:52:57Z"),
                     DedupToken.Key("abc@example.com", "2026-03-20T21:52:57Z"));
    }

    [Fact]
    public void Key_needs_both_parts()
    {
        Assert.Null(DedupToken.Key(null, "2026-03-20T21:52:57Z"));
        Assert.Null(DedupToken.Key("abc@example.com", null));
        Assert.Null(DedupToken.Key("", ""));
    }

    [Fact]
    public void CleanMid_strips_control_characters_before_the_angle_brackets()
    {
        // A real message in the June 2024 batch carried a NUL immediately after '>'.
        // Stripping <> first cannot reach it, and the id would then key differently from
        // the same message read as .msg - dedup broken with nothing visible to show it.
        Assert.Equal("abc@example.com", DedupToken.CleanMid("<abc@example.com>\0"));
        Assert.Equal("abc@example.com", DedupToken.CleanMid("  <abc@example.com>  "));
        Assert.Equal("abc@example.com", DedupToken.CleanMid("abc@example.com"));
    }

    [Fact]
    public void CleanMid_returns_null_for_nothing_usable()
    {
        Assert.Null(DedupToken.CleanMid(null));
        Assert.Null(DedupToken.CleanMid("   "));
        Assert.Null(DedupToken.CleanMid("<>"));
    }

    [Fact]
    public void SentUtc_converts_an_offset_to_utc_to_the_second()
    {
        Assert.Equal("2026-05-04T17:33:58Z", DedupToken.SentUtc("Mon, 4 May 2026 10:33:58 -0700"));
        Assert.Equal("2026-03-20T21:52:57Z", DedupToken.SentUtc("Fri, 20 Mar 2026 21:52:57 +0000"));
    }

    [Fact]
    public void SentUtc_returns_null_for_an_unparseable_date()
    {
        Assert.Null(DedupToken.SentUtc(null));
        Assert.Null(DedupToken.SentUtc("not a date"));
    }

    [Fact]
    public void FromBytes_reads_an_eml_header_block()
    {
        byte[] eml = Encoding.ASCII.GetBytes(string.Join("\r\n",
            "From: a@example.com",
            "To: b@example.com",
            "Subject: hello",
            "Date: Fri, 20 Mar 2026 21:52:57 +0000",
            "Message-ID: <abc@example.com>",
            "",
            "body text"));

        var (token, mid, sent) = DedupToken.FromBytes(eml);

        Assert.Equal("abc@example.com", mid);
        Assert.Equal("2026-03-20T21:52:57Z", sent);
        Assert.Equal(DedupToken.Key("abc@example.com", "2026-03-20T21:52:57Z"), token);
    }

    [Fact]
    public void FromBytes_returns_no_token_when_identity_is_missing()
    {
        byte[] noId = Encoding.ASCII.GetBytes("Subject: hello\r\n\r\nbody");

        var (token, _, _) = DedupToken.FromBytes(noId);

        Assert.Null(token);
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
dotnet test RegExAzFunc.Tests --filter DedupTokenTests
```

Expected: FAIL — `DedupToken` does not exist.

- [ ] **Step 3: Write `DedupToken.cs`**

```csharp
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using MimeKit;
using MimeKit.Utils;

namespace Company.Function;

/// <summary>
/// The identity of an archived message: sha256 over its Message-ID and sent date.
///
/// This is a port of ingest-key.py's dedup_key/clean_mid/sent_utc, and it must stay one.
/// 401,170 blob names already encode that function's output, so a drift of one character
/// here does not throw - it silently writes a second copy of a message that is already
/// archived, which is the exact defect this whole change exists to remove.
/// </summary>
internal static class DedupToken
{
    private static readonly Regex Ctrl = new(@"[\x00-\x1f\x7f]+", RegexOptions.Compiled);

    /// <summary>
    /// Normalise a Message-ID to its bare form.
    /// <para>
    /// Control characters go FIRST. A real message in the June 2024 batch carried a NUL
    /// immediately after the closing '&gt;', so stripping '&lt;&gt;' first could not reach
    /// it and the id kept the bracket - keying that message differently from the same
    /// message read as .msg, and breaking dedup with no visible error.
    /// </para>
    /// </summary>
    internal static string? CleanMid(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) { return null; }
        string mid = Ctrl.Replace(raw, "").Trim().Trim('<', '>').Trim();
        return mid.Length == 0 ? null : mid;
    }

    /// <summary>RFC 5322 Date -&gt; 'yyyy-MM-ddTHH:mm:ssZ', or null if unparseable.</summary>
    internal static string? SentUtc(string? rawDate)
    {
        if (string.IsNullOrWhiteSpace(rawDate)) { return null; }
        // MimeKit parses the RFC 2822 forms this corpus actually contains, including the
        // obsolete zone names DateTimeOffset.Parse rejects.
        if (!DateUtils.TryParse(rawDate, out DateTimeOffset dt)) { return null; }
        return dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss") + "Z";
    }

    /// <summary>Stable identity for one message. Both parts required.</summary>
    internal static string? Key(string? mid, string? sent)
    {
        if (string.IsNullOrEmpty(mid) || string.IsNullOrEmpty(sent)) { return null; }
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{mid.ToLowerInvariant()}|{sent}"));
        return "k" + Convert.ToHexString(hash).ToLowerInvariant()[..22];
    }

    private static ReadOnlySpan<byte> Ole2Signature => [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

    /// <summary>
    /// Derive identity from raw message bytes - the same source ingest-key.py used.
    /// <para>
    /// Handles both formats it handles, because this is meant to be the one implementation:
    /// MIME from the pipeline, and the compound-file .msg the ingest wrote. The conformance
    /// check posts real ingested .msg blobs, so a MIME-only version would fail the very
    /// test that proves this agrees with the 401,170 tokens already in the container.
    /// </para>
    /// <para>
    /// Format is decided by the OLE2 signature, never by an extension. The ingest derived
    /// blob names from subjects, so a name says nothing about content.
    /// </para>
    /// </summary>
    internal static (string? Token, string? MessageId, string? SentUtc) FromBytes(byte[] bytes)
    {
        try
        {
            if (bytes.Length >= 8 && bytes.AsSpan(0, 8).SequenceEqual(Ole2Signature))
            {
                using var msgStream = new MemoryStream(bytes);
                using var msg = new MsgReader.Outlook.Storage.Message(msgStream);
                string? msgMid = CleanMid(msg.GetEmailHeaders()?.MessageId);
                string? msgSent = msg.SentOn.HasValue
                    ? msg.SentOn.Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
                    : null;
                return (Key(msgMid, msgSent), msgMid, msgSent);
            }

            using var stream = new MemoryStream(bytes);
            var parser = new MimeParser(stream, MimeFormat.Entity);
            MimeMessage message = parser.ParseMessage();
            string? mid = CleanMid(message.Headers["Message-ID"] ?? message.Headers["Message-Id"]);
            string? sent = SentUtc(message.Headers["Date"]);
            return (Key(mid, sent), mid, sent);
        }
        catch (Exception)
        {
            // A truncated or corrupt message has no identity. Callers fall back; they never
            // fail the archive over it.
            return (null, null, null);
        }
    }
}
```

If MsgReader's accessor for the transport Message-ID differs in the installed version,
adjust **only** that accessor — `CleanMid`, `SentUtc` and `Key` are what the conformance
test pins, and changing them to make a build succeed would defeat the exercise. The
file-tree work solved the same problem in `MsgProjection.Read`; read it before guessing.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
dotnet test RegExAzFunc.Tests --filter DedupTokenTests
```

Expected: PASS, 9 tests.

- [ ] **Step 5: Write the HTTP endpoint**

Create `RegExAzFunc/DedupTokenFunc.cs`:

```csharp
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Company.Function;

/// <summary>
/// The k-token for a message, so the archive can name mail after the message rather than
/// after the mailbox copy it arrived in.
///
///   POST                      body: raw .eml/.msg bytes    -> one token
///   POST ?from=fields         body: [{id, messageId, sentDateTime}, ...] -> many tokens
///
/// Two routes because the callers can afford different things. The Logic App holds the
/// bytes already and must be exact - a wrong token there writes a mis-named blob. A sweep
/// walking 198,000 messages cannot fetch each one's MIME, and can afford to be wrong,
/// because a wrong token there only re-queues a message the pipeline then overwrites.
/// </summary>
public class DedupTokenFunc
{
    public class FieldsRequest
    {
        [JsonPropertyName("id")] public string Id { get; set; } = "";
        [JsonPropertyName("messageId")] public string? MessageId { get; set; }
        [JsonPropertyName("sentDateTime")] public string? SentDateTime { get; set; }
    }

    private readonly ILogger<DedupTokenFunc> _logger;

    public DedupTokenFunc(ILogger<DedupTokenFunc> logger) => _logger = logger;

    [Function("DedupTokenFunc")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequest req)
    {
        if (string.Equals(req.Query["from"], "fields", StringComparison.OrdinalIgnoreCase))
        {
            return await FromFields(req);
        }

        using var ms = new MemoryStream();
        await req.Body.CopyToAsync(ms);
        var (token, mid, sent) = DedupToken.FromBytes(ms.ToArray());
        if (token == null)
        {
            // Not an error the caller should retry: this message has no derivable identity
            // and never will. 422 tells the Logic App to fall back rather than stall.
            return new ObjectResult(new { error = "no Message-ID or Date" })
            { StatusCode = StatusCodes.Status422UnprocessableEntity };
        }
        return new OkObjectResult(new { token, messageId = mid, sentUtc = sent });
    }

    private async Task<IActionResult> FromFields(HttpRequest req)
    {
        List<FieldsRequest>? items;
        try
        {
            items = await JsonSerializer.DeserializeAsync<List<FieldsRequest>>(req.Body);
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult(new { error = "Malformed JSON payload." });
        }
        if (items == null) { return new BadRequestObjectResult(new { error = "Expected an array." }); }

        var results = items.Select(i => new
        {
            id = i.Id,
            // The same normalisation the bytes route uses. Only the source of the two
            // inputs differs, which is the whole point of sharing DedupToken.
            token = DedupToken.Key(DedupToken.CleanMid(i.MessageId),
                                   DedupToken.SentUtc(i.SentDateTime))
        }).ToList();

        return new OkObjectResult(results);
    }
}
```

- [ ] **Step 6: Build and run the whole suite**

```bash
dotnet build RegExAzFunc/RegExAzFunc.csproj --no-incremental -v q --nologo
dotnet test RegExAzFunc.Tests --nologo
```

Expected: build clean with no new warnings; all tests pass, including the pre-existing ones.

- [ ] **Step 7: Commit**

```bash
git add RegExAzFunc/DedupToken.cs RegExAzFunc/DedupTokenFunc.cs RegExAzFunc.Tests/DedupTokenTests.cs
git commit -m "Add the one implementation of the message identity token"
```

---

### Task 3: Prove the Function against tokens already in the container

Unit tests prove the C# agrees with itself. This proves it agrees with the 401,170 tokens `ingest-key.py` already wrote into blob names — which is the claim that actually matters.

**Files:**
- Create: `RegExAzFunc.Tests/DedupTokenConformanceTests.cs`
- Modify: `infra/logicapps/tools/dedup-plan.py` (add a `conformance` command)

**Interfaces:**
- Consumes: `DedupToken.Key`, `DedupToken.CleanMid`, `DedupToken.SentUtc` (Task 2).
- Produces: evidence, and a repeatable check. No API other tasks call.

- [ ] **Step 1: Write a conformance test over fixtures**

Create `RegExAzFunc.Tests/DedupTokenConformanceTests.cs`. The fixtures are (messageId, sentUtc, expectedToken) triples generated by the Python reference — no real correspondence, only identifiers and hashes.

```csharp
using Company.Function;

namespace RegExAzFunc.Tests;

/// <summary>
/// The C# token must equal what ingest-key.py produced, because 401,170 blob names already
/// encode the Python function's output. These triples were generated by that function.
/// </summary>
public class DedupTokenConformanceTests
{
    public static TheoryData<string, string, string> Reference => new()
    {
        // Generated by ingest-key.py's dedup_key(mid, sent) on 2026-09-08. Do not edit by
        // hand: if C# disagrees with a row, the C# is wrong, because these are what named
        // 401,170 blobs. Step 2 regenerates them.
        { "abc@example.com", "2026-03-20T21:52:57Z", "k5e610767040b7fc3c8b636" },
        { "ABC@Example.COM", "2026-03-20T21:52:57Z", "k5e610767040b7fc3c8b636" },
        { "DS0PR10MB7361@DS0PR10MB7361.prod.com", "2025-09-22T23:36:06Z", "k6031a596c24c60cb439873" },
        { "a+b/c=d@example.com", "2024-01-01T00:00:00Z", "kb7cd42df10cc39613703fe" },
    };

    [Theory]
    [MemberData(nameof(Reference))]
    public void Csharp_reproduces_the_python_token(string mid, string sent, string expected)
    {
        Assert.Equal(expected, DedupToken.Key(mid, sent));
    }
}
```

- [ ] **Step 2: Confirm the fixtures still come from the Python reference**

The rows above were generated on 2026-09-08. Regenerate and diff, so a later change to
`ingest-key.py` cannot pass unnoticed:

```bash
cd infra/logicapps/tools
python - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('ingest_key', 'ingest-key.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases = [
    ('abc@example.com',                      '2026-03-20T21:52:57Z'),
    ('ABC@Example.COM',                      '2026-03-20T21:52:57Z'),
    ('DS0PR10MB7361@DS0PR10MB7361.prod.com', '2025-09-22T23:36:06Z'),
    ('a+b/c=d@example.com',                  '2024-01-01T00:00:00Z'),
]
for mid, sent in cases:
    print(f'        {{ "{mid}", "{sent}", "{m.dedup_key(mid, sent)}" }},')
PY
```

Expected: output identical to the four rows in `Reference`. If it differs, `ingest-key.py`
has changed and the whole archive's identity is in question — stop and understand why
before touching the C#.

- [ ] **Step 3: Run the conformance test**

```bash
dotnet test RegExAzFunc.Tests --filter DedupTokenConformanceTests
```

Expected: PASS, 5 cases. A failure here means the C# and Python disagree — stop and fix the C#, never the fixtures.

- [ ] **Step 4: Add a `conformance` command to the dry-run planner**

The fixtures prove the hash. This proves the whole chain against real blob names, the way `dedup-plan.py selftest` already does for Python. Add to `infra/logicapps/tools/dedup-plan.py`, registering `conformance` beside the existing subcommands:

```python
def cmd_conformance(args):
    """Check the deployed Function reproduces the tokens in real ingested blob names.

    selftest proves ingest-key.py still agrees with what it wrote. This proves the C#
    Function agrees too - the claim that lets the pipeline and the ingest share one
    identity. Sends only headers, never whole messages.
    """
    import urllib.request
    key_mod = load_ingest_key()
    storage = Storage()

    named = []
    with open(args.index, encoding='utf-8') as fh:
        fh.readline()
        for line in fh:
            blob = line.split('\t', 1)[0]
            if token_from_name(blob):
                named.append(blob)
            if len(named) >= args.sample * 4:
                break
    sample = named[::4][:args.sample]
    print(f'checking {len(sample)} ingested blobs against {args.func}\n')

    ok = bad = failed = 0
    for i, blob in enumerate(sample, 1):
        expected = token_from_name(blob)
        try:
            raw, _, _ = storage.head_bytes_sized(blob, 40 * 1024 * 1024)
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            print(f'  [{i}/{len(sample)}] fetch failed ({type(e).__name__})')
            continue
        req = urllib.request.Request(args.func, data=raw,
                                     headers={'Content-Type': 'application/octet-stream'})
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                got = json.loads(resp.read()).get('token')
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            print(f'  [{i}/{len(sample)}] function call failed ({type(e).__name__})')
            continue
        if got == expected:
            ok += 1
        else:
            bad += 1
            print(f'  [{i}/{len(sample)}] MISMATCH name={expected} function={got}')

    print(f'\nmatched {ok}, mismatched {bad}, unreadable {failed}')
    if bad:
        print('\nThe Function does not reproduce the tokens already in the container.\n'
              'Do not wire anything to it until this is understood.')
        return 1
    if not ok:
        print('\nNothing verified. Treat the Function as unproven.')
        return 1
    print('\nThe Function agrees with the names already in the container.')
    return 0
```

Register it in `main()` alongside the other subcommands:

```python
    cf = sub.add_parser('conformance', help='check the deployed Function against real blob names')
    cf.add_argument('--sample', type=int, default=40)
    cf.add_argument('--index', default=INDEX)
    cf.add_argument('--func', required=True, help='DedupTokenFunc URL including ?code=')
```

and dispatch it before the index check, next to `review`:

```python
    if args.cmd == 'review':
        return cmd_review(args)
    if args.cmd == 'conformance':
        if not os.path.exists(args.index):
            sys.exit(f'no Message-ID index at {args.index}')
        return cmd_conformance(args)
```

- [ ] **Step 5: Deploy the Function and run the conformance check**

Zip-deploy replaces every function in the app, so build from a branch carrying all of them (see Global Constraints).

```bash
cd RegExAzFunc
rm -rf publish_output
dotnet publish RegExAzFunc.csproj -c Release -o publish_output --nologo
```

Name the `.csproj` explicitly — a bare `dotnet publish` builds the whole solution and ships `RegExAzFunc.Tests.dll` plus xunit into the package.

```powershell
Compress-Archive -Path publish_output\* -DestinationPath publish.zip -Force
az functionapp deployment source config-zip --name RegExAzFunc --resource-group regexazfunc2 --src publish.zip
```

Run that `az` command from PowerShell — the Bash tool's worktree guard trips on the word `source`.

Then get the key and check:

```powershell
az functionapp function keys list --name RegExAzFunc --resource-group regexazfunc2 --function-name DedupTokenFunc --query default -o tsv
```

```bash
python infra/logicapps/tools/dedup-plan.py conformance --sample 40 \
  --func "https://regexazfunc.azurewebsites.net/api/DedupTokenFunc?code=<key>" \
  --index <path to messageid-index.tsv>
```

Expected: `matched 40, mismatched 0`. **A single mismatch stops the rollout** — nothing else in this plan may proceed until it is understood.

- [ ] **Step 6: Prove a Logic App can actually post a message body to it**

The spec lists this as its first load-bearing unknown: the workflow demonstrably hands
`$value` to the blob connector, but that is not the same as posting those bytes as an HTTP
body. It could not be tested before now because there was nothing to post to. It must be
tested before Task 7 writes the change into the production workflow.

Build a scratch Consumption Logic App in the same resource group with three actions:

1. a **Recurrence** trigger (any interval — it will be run manually);
2. an **HTTP GET** to `https://graph.microsoft.com/v1.0/users/matters@rse-law.com/messages?$top=1&$select=id`, managed-identity auth, audience `https://graph.microsoft.com` — then a second GET to that message's `/$value` with `runtimeConfiguration.contentTransfer.transferMode = Chunked`, exactly as `HTTP_Graph_API_Call_to_Get_Email_Message_Value` does;
3. an **HTTP POST** to the `DedupTokenFunc` URL with `body: @body('<the $value action>')` and `Content-Type: application/octet-stream`.

Run it once. Expected: the POST returns 200 with a `token` field.

**If it fails**, stop and report rather than working around it. The fallback is the fields
route for the pipeline too, which the spec argued against because Graph's `sentDateTime` is
a second source of truth for the date — that is a decision for the archive owner, not a
workaround to apply quietly. Task 1's measurement tells you how much risk that carries.

Delete the scratch Logic App afterwards.

- [ ] **Step 7: Commit**

```bash
git add RegExAzFunc.Tests/DedupTokenConformanceTests.cs infra/logicapps/tools/dedup-plan.py
git commit -m "Prove the Function reproduces the tokens already in the container"
```

---

### Task 4: Teach reconcile-missed.ps1 both naming schemes

First of the predictors. After this, the script recognises `k`-token blobs that do not exist yet — harmless, and required before the pipeline can write one.

**Files:**
- Modify: `infra/logicapps/tools/reconcile-missed.ps1` (`Get-IdTail` around line 76; the archived-set build around line 167; the membership check around line 258)

**Interfaces:**
- Consumes: `DedupTokenFunc?from=fields` (Task 2), proven by Task 3.
- Produces: `Get-KTokens` — a batch helper the next two tasks copy verbatim.

- [ ] **Step 1: Confirm the set build already captures k-tokens**

```bash
grep -n 'match .\[(\[^\\]\]+)\]' infra/logicapps/tools/reconcile-missed.ps1
```

Expected: the existing `'\[([^\]]+)\]\.eml$'` regex. It captures whatever sits in brackets, so it already admits `k`-tokens and needs no change. Confirm this before editing — the change below assumes it.

- [ ] **Step 2: Add the batch token helper**

Insert after `Get-IdTail`:

```powershell
<#
The k-token for a batch of messages, from the Function that owns the rule.

Deliberately not reimplemented here. The token exists in exactly one place - a PowerShell
copy that drifted by one character would not throw, it would quietly stop recognising
archived mail and re-upload it.

sentDateTime is Graph's record rather than the Date: header every existing token came from.
That substitution is safe HERE and nowhere else: a wrong token makes this script think a
message is missing, it re-queues it, and the pipeline archives it under the authoritative
token - the same name it already has - and overwrites. Wrong costs bandwidth, not a
duplicate. See the spec's "The sweeps get the cheap route the pipeline cannot have".
#>
function Get-KTokens {
  param([array]$Messages, [string]$FuncUrl)
  if (-not $FuncUrl -or -not $Messages.Count) { return @{} }
  $map = @{}
  for ($i = 0; $i -lt $Messages.Count; $i += 500) {
    $chunk = $Messages[$i..([Math]::Min($i + 499, $Messages.Count - 1))]
    $body = @($chunk | ForEach-Object {
      @{ id = $_.id; messageId = $_.internetMessageId; sentDateTime = $_.sentDateTime }
    }) | ConvertTo-Json -Depth 4 -AsArray
    try {
      $res = Invoke-RestMethod -Method Post -Uri "$FuncUrl&from=fields" `
               -ContentType 'application/json' -Body $body -TimeoutSec 120
      foreach ($r in $res) { if ($r.token) { $map[$r.id] = $r.token } }
    } catch {
      # No token means this batch falls back to legacy-tail matching only, which is how
      # the script behaved before. Never fatal.
      Write-Warning "token service unavailable for a batch of $($chunk.Count): $($_.Exception.Message)"
    }
  }
  return $map
}
```

- [ ] **Step 3: Add the parameter and widen the Graph $select**

Add to the `param(...)` block:

```powershell
  [string]$TokenFuncUrl = $env:DEDUP_TOKEN_FUNC_URL,
```

Then find the message-paging URL and add the two fields to its `$select`. It currently selects `id` and others; add `internetMessageId,sentDateTime`. They arrive in the same call, so this costs nothing.

- [ ] **Step 4: Check both schemes at the membership test**

Replace the check at roughly line 258:

```powershell
      $tail = Get-IdTail $m.id
      if ($archived.Contains($tail)) { continue }
```

with:

```powershell
      # Either scheme counts as archived. Legacy names are never rewritten, so a message
      # archived before the pipeline switched is found by its tail forever; one archived
      # after is found by its token.
      $tail = Get-IdTail $m.id
      $ktok = $kTokens[$m.id]
      if ($archived.Contains($tail) -or ($ktok -and $archived.Contains($ktok))) { continue }
```

and populate `$kTokens` once per page, immediately after the page is fetched and before the `foreach ($m in $page.value)` loop:

```powershell
    $kTokens = Get-KTokens -Messages $page.value -FuncUrl $TokenFuncUrl
```

- [ ] **Step 5: Verify against the live archive, read-only**

The script's default is a report; make sure that is the mode used.

```bash
pwsh infra/logicapps/tools/reconcile-missed.ps1 -TokenFuncUrl "https://regexazfunc.azurewebsites.net/api/DedupTokenFunc?code=<key>"
```

Expected: the "missing" count is **the same or lower** than a run without `-TokenFuncUrl`. It can only fall, because the change adds a second way to match and removes none. Run it both ways and compare — a higher count means the change is wrong.

- [ ] **Step 6: Commit**

```bash
git add infra/logicapps/tools/reconcile-missed.ps1
git commit -m "Recognise a message archived under either naming scheme"
```

---

### Task 5: Teach sweep-older-mail.ps1 both naming schemes

**Files:**
- Modify: `infra/logicapps/tools/sweep-older-mail.ps1` (`Get-IdTail` at line 63; `$tails` build at lines 87-89; membership check at line 142; `$select` at line 123)

**Interfaces:**
- Consumes: the same `DedupTokenFunc?from=fields` endpoint and the `Get-KTokens` helper written in Task 4.
- Produces: nothing other tasks consume.

- [ ] **Step 1: Copy the batch helper**

Insert the same `Get-KTokens` function from Task 4 Step 2, verbatim including its comment block, after `Get-IdTail` at line 63. Repeating it is deliberate: these scripts are run standalone and already each carry their own copy of `Get-IdTail` for the same reason.

- [ ] **Step 2: Add the parameter**

Add to `param(...)`:

```powershell
  [string]$TokenFuncUrl = $env:DEDUP_TOKEN_FUNC_URL,
```

- [ ] **Step 3: Widen the $select**

At line 123, change:

```powershell
     "&`$select=id,subject,receivedDateTime,parentFolderId&`$top=200"
```

to:

```powershell
     "&`$select=id,subject,receivedDateTime,parentFolderId,internetMessageId,sentDateTime&`$top=200"
```

- [ ] **Step 4: Check both schemes**

Immediately after the page is fetched and before `foreach ($m in $page.value)`, add:

```powershell
  $kTokens = Get-KTokens -Messages $page.value -FuncUrl $TokenFuncUrl
```

Then replace the check at line 142:

```powershell
    $tail = Get-IdTail $m.id
    if ($tails.Contains($tail)) { $already++; continue }
```

with:

```powershell
    # Either scheme counts as archived - see the note on Get-KTokens.
    $tail = Get-IdTail $m.id
    $ktok = $kTokens[$m.id]
    if ($tails.Contains($tail) -or ($ktok -and $tails.Contains($ktok))) { $already++; continue }
```

- [ ] **Step 5: Verify read-only**

This script queues work, so run it in whatever mode reports without sending. Check the parameter block for the switch that does this (the script follows the repo's `-Execute` convention) and run without it:

```bash
pwsh infra/logicapps/tools/sweep-older-mail.ps1 -TokenFuncUrl "https://regexazfunc.azurewebsites.net/api/DedupTokenFunc?code=<key>"
```

Expected: the `$already` count is **the same or higher** than a run without the token URL, and the queued count the same or lower. Compare both ways; queued going up means the change is wrong.

- [ ] **Step 6: Commit**

```bash
git add infra/logicapps/tools/sweep-older-mail.ps1
git commit -m "Recognise both naming schemes when sweeping older mail"
```

---

### Task 6: Correct sweep-inbox.ps1's collision counting

This script does not do an archived-set membership check in its main path, so it needs less than the other two. What it does do is count blob-name collisions — and after the cutover it would be counting collisions on an identifier the blob names no longer use.

**Files:**
- Modify: `infra/logicapps/sweep-inbox.ps1` (the comment at lines 136-147; collision counting at lines 183-195)

**Interfaces:**
- Consumes: `Get-KTokens` (Task 4), `DedupTokenFunc?from=fields` (Task 2).
- Produces: nothing.

- [ ] **Step 1: Correct the naming contract comment**

The block at lines 136-147 says the tail "MUST match transform.ps1's $idTail exactly." That stops being the whole truth once the pipeline writes `k`-tokens. Replace the "This MUST match" sentence with:

```
The pipeline now names blobs by the k-token (sha256 of Message-ID + sent date) and falls
back to this tail only when the token service is unavailable, so a blob name may carry
either. This transform still has to match transform.ps1's fallback exactly:
    last 24 chars, then '/'->'_', '+'->'-', '=' dropped
The token half is not reimplemented here - DedupTokenFunc owns it. See
docs/superpowers/specs/2026-09-08-logic-app-k-token-naming-design.md.
```

- [ ] **Step 2: Copy the batch helper and add the parameter**

Insert `Get-KTokens` from Task 4 Step 2 verbatim after `Get-IdTail` at line 144, and add to `param(...)`:

```powershell
  [string]$TokenFuncUrl = $env:DEDUP_TOKEN_FUNC_URL,
```

- [ ] **Step 3: Widen the $select**

At line 176, change:

```powershell
         "?`$select=id&`$top=999&`$orderby=receivedDateTime asc"
```

to:

```powershell
         "?`$select=id,internetMessageId,sentDateTime&`$top=999&`$orderby=receivedDateTime asc"
```

- [ ] **Step 4: Count collisions on the identifier the name will actually use**

After the page is fetched, add:

```powershell
      $kTokens = Get-KTokens -Messages $page.value -FuncUrl $TokenFuncUrl
```

Then at line 188, replace:

```powershell
      $mTail = Get-IdTail $m.id
```

with:

```powershell
      # Count collisions on whatever the blob name will actually carry. Counting the Graph
      # tail after the pipeline switched would measure an identifier no new name uses, and
      # report a clean result while real collisions went unseen.
      $mTail = if ($kTokens[$m.id]) { $kTokens[$m.id] } else { Get-IdTail $m.id }
```

- [ ] **Step 5: Verify**

```bash
pwsh infra/logicapps/sweep-inbox.ps1 -WhatIf -TokenFuncUrl "https://regexazfunc.azurewebsites.net/api/DedupTokenFunc?code=<key>"
```

If the script has no `-WhatIf`, use whatever non-sending mode its parameter block provides. Expected: it runs to completion and reports a collision count. Without `-TokenFuncUrl` it must behave exactly as before.

- [ ] **Step 6: Commit**

```bash
git add infra/logicapps/sweep-inbox.ps1
git commit -m "Count name collisions on the identifier the name will carry"
```

---

### Task 7: Switch the Logic App

Last, because the predictors must already understand `k`-tokens before the pipeline writes one.

**Files:**
- Modify: `infra/logicapps/transform.ps1` (`$idTail` at line 329; the `Email_Blob_Name` action; the attachment `folderPath` at line 407)

**Interfaces:**
- Consumes: `DedupTokenFunc` bytes endpoint (Task 2), proven by Task 3; predictors from Tasks 4-6.
- Produces: the deployed workflow.

- [ ] **Step 1: Add the token call and the fallback**

`transform.ps1` generates workflow actions as a PowerShell hashtable. Add two actions to `$found.actions`, placed after the message body is available and before `Email_Blob_Name`:

```powershell
  Get_Dedup_Token = @{
    type = 'Http'
    runAfter = @{ HTTP_Graph_API_Call_to_Get_Email_Message_Value = @('Succeeded') }
    <#
    The k-token for this message, from the Function that owns the rule. Posting the MIME
    rather than fields taken from Graph is deliberate: every existing token came from the
    message's own Date: header, and Graph's sentDateTime is a second source of truth for
    it. A one-second disagreement would write a second copy of an already-archived
    message, which is the defect this change exists to remove.
    #>
    inputs = @{
      method = 'POST'
      uri    = "@parameters('dedupTokenFuncUrl')"
      body   = "@body('HTTP_Graph_API_Call_to_Get_Email_Message_Value')"
      headers = @{ 'Content-Type' = 'application/octet-stream' }
    }
    runtimeConfiguration = @{ contentTransfer = @{ transferMode = 'Chunked' } }
  }
  Message_Identifier = @{
    type = 'Compose'
    # Succeeded OR Failed: a naming call must never be able to stop mail being archived.
    # 422 means this message has no derivable identity; a 5xx or timeout means the service
    # is unwell. Both fall back to the Graph-id tail, which is exactly today's behaviour.
    runAfter = @{ Get_Dedup_Token = @('Succeeded', 'Failed', 'TimedOut', 'Skipped') }
    inputs = "@coalesce(body('Get_Dedup_Token')?['token'], $idTail)"
  }
```

- [ ] **Step 2: Point both names at the single identifier**

Change `Email_Blob_Name` to depend on the new action and use it:

```powershell
  Email_Blob_Name = @{
    type = 'Compose'
    runAfter = @{ Email_Subject_Clean = @('Succeeded'); Message_Identifier = @('Succeeded') }
    inputs = "@concat($emlStem, ' [', outputs('Message_Identifier'), '].eml')"
  }
```

and the attachment folder at line 407:

```powershell
            folderPath = "/matters/@{variables('strFoundMatter')}/Emails/Attachments/@{outputs('Message_Identifier')}/"
```

Both now read the same action, which is what makes the choice atomic per message — a `k`-token `.eml` can never sit beside an `$idTail` attachment folder.

- [ ] **Step 3: Add the workflow parameter**

Find where `transform.ps1` defines workflow parameters and add `dedupTokenFuncUrl` as a string, so the Function URL and its key are configuration rather than a literal in the definition. Follow whatever pattern the file already uses for parameters.

- [ ] **Step 4: Regenerate and diff before deploying**

```bash
pwsh infra/logicapps/transform.ps1
```

Then inspect the generated definition against the deployed one:

```bash
pwsh infra/logicapps/drift.ps1
```

Expected: the only differences are the two new actions, the two changed `inputs`, and the new parameter. Anything else means `transform.ps1` was edited more broadly than intended — stop and narrow it.

- [ ] **Step 5: Deploy and watch the first runs**

```bash
pwsh infra/logicapps/deploy.ps1
```

Then confirm, in the Logic App run history, that the first handful of runs:

1. succeeded;
2. show `Get_Dedup_Token` returning a token;
3. wrote a blob whose name ends `[k<22 hex>].eml`;
4. put that message's attachments under `Attachments/k<22 hex>/`.

Then force the fallback — temporarily set `dedupTokenFuncUrl` to an unreachable URL, send one test message, and confirm it still archives, under a legacy `$idTail` name, with its attachments under the matching legacy folder. Restore the parameter afterwards. **This is the most important check in the plan**: it proves a naming call cannot lose mail.

- [ ] **Step 6: Commit**

```bash
git add infra/logicapps/transform.ps1 infra/logicapps/deployed.json
git commit -m "Name archived mail by the message, not by the mailbox copy"
```

---

## After the rollout

The pipeline stops creating duplicates from this point. It does not remove the 68,730 already planned in `dedup-manifest.tsv` — that is the separate cleanup, whose deletion pass still does not exist.

Re-run the duplicate measurement a week after deployment and confirm the count is flat rather than climbing. The query is in `2026-09-08-duplicate-blob-cleanup-design.md`; a still-climbing count means a path is writing legacy names more often than the 0.052% fallback rate predicts.

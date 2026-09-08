# Matters File Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a lazy file-explorer pane over the `samatters/matters` blob container to the Outlook search web part, with `.eml`/`.msg` preview, per-row download, and a folder-level zip that includes attachments.

**Architecture:** A new `MattersBrowseFunc` Azure Function serves three operations — `list` (one directory level via blob hierarchy listing), `probe` (an early-exit walk that answers "is this folder within the download cap"), and `zip` (a streamed archive). Blob plumbing shared with the existing `EmlPreviewFunc` moves into a `MattersBlobs` helper. On the client, a `FileTree` pane joins the existing list and reading panes, driven by a `BlobBrowseService`; tree rows reuse the existing preview and download endpoints unchanged.

**Tech Stack:** C# / .NET 10 isolated Azure Functions (`Microsoft.Azure.Functions.Worker` 2.51.0), `Azure.Storage.Blobs` 12.24.0, MimeKit 4.9.0, MsgReader (new), xunit (new); SPFx 1.23.2, React 17, Fluent UI 8, jest via `heft test`.

**Spec:** `docs/superpowers/specs/2026-09-07-samatters-file-tree-design.md`

## Global Constraints

- **Base branch:** `samatters-file-tree`, cut from `main`. The spec was measured partly on `archive-ingest-dedup-key`; two of its claims do not hold on `main` and are corrected in Task 0.
- **Download cap:** 2,000 files **or** 2 GB, whichever is hit first. One pair of constants, surfaced in the 413 body.
- **Cap wording:** past the cap the true count is unknown. UI and API text say **"more than 2,000 files"** — never a count the walk did not finish.
- **`path` values are full blob URLs**: `https://samatters.blob.core.windows.net/matters/<name>`. `MattersBlobs.DecodeStoragePath` already accepts that form.
- **`kind`**: `'attachment'` when the blob name contains `/Attachments/`, else by extension (`.eml` → `eml`, `.msg` → `msg`, otherwise `other`).
- **Auth:** `AuthorizationLevel.Function`, matching `EmlPreviewFunc`. The storage credential stays in the function; the page holds only a function key.
- **Container allow-list:** every path is validated against `MATTERS_CONTAINER_URL` (default `https://samatters.blob.core.windows.net/matters/`). Nothing outside it is ever served.
- **No real correspondence in fixtures.** The container holds live client mail. Test fixtures are synthesised or faked; real `.msg`/`.eml` bytes are never committed to the repo.
- **Existing behaviour is not to regress:** `EmlPreviewFunc`'s three routes (POST preview, `?path=`, `?path=&att=`) keep their current contract.

## Two deliberate departures from the spec's file table

Both are consolidations found while writing the tasks. Neither changes behaviour.

- **No `components/FileTreeRow.tsx`.** The row is a `renderRow` function inside `FileTree.tsx`, because Fluent's `List` takes a render callback rather than a component and the row closes over the tree's handlers. Splitting it would mean threading six callbacks through props for no gain.
- **`services/downloadUrls.ts` is not extended.** Browse URL building lives in `BlobBrowseService`, next to the calls that use it, so the list/probe/zip contract is described in exactly one file. `downloadUrls.ts` keeps serving the preview function unchanged, and `OutlookSearch.tsx` still imports `emlDownloadUrl` from it for tree row downloads.

---

### Task 0: Correct the spec's two branch-dependent claims

The spec asserts facts measured on the ingest branch. Fix them before building on them.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-07-samatters-file-tree-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — a documentation correction.

- [ ] **Step 1: Verify both claims against the current branch**

```bash
git rev-parse --abbrev-ref HEAD                      # expect: samatters-file-tree
grep -c MsgReader RegExAzFunc/RegExAzFunc.csproj     # expect: 0
grep -n "items.map(" OutlookSearchSPFxWebPart/outlook-search-spfx/src/webparts/outlookSearch/components/EmailList.tsx
```

Expected: `MsgReader` absent from the csproj, and `EmailList.tsx` rendering with `items.map(` — it is not virtualized.

- [ ] **Step 2: Correct the "Fixing .msg preview" section**

Replace the sentence reading `MsgReader 6.1.0 is already a RegExAzFunc.csproj dependency but is never referenced from EmlPreviewFunc.cs` with:

```markdown
`MsgReader` is **not** a dependency on `main` — the ingest branch adds it for the
attachment-names skill, and that branch is unmerged. This work adds the package
reference itself.
```

- [ ] **Step 3: Correct the virtualization claim**

Replace `Rows render through Fluent's virtualized List over a flat array of visible nodes derived from expansion state — the pattern the result list already uses.` with:

```markdown
Rows render through Fluent's virtualized `List` over a flat array of visible nodes
derived from expansion state. This is a new pattern in this web part: the result list
renders with `items.map()` and gets away with it because it pages 25 at a time. The
tree cannot — the root alone is 1,519 rows.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-09-07-samatters-file-tree-design.md
git commit -m "Correct two branch-dependent claims in the file tree spec"
```

---

### Task 1: Extract shared blob plumbing into `MattersBlobs`

A pure refactor with characterization tests written first, plus the xunit project the rest of the C# work needs.

**Files:**
- Create: `RegExAzFunc.Tests/RegExAzFunc.Tests.csproj`
- Create: `RegExAzFunc.Tests/MattersBlobsTests.cs`
- Create: `RegExAzFunc/MattersBlobs.cs`
- Modify: `RegExAzFunc/EmlPreviewFunc.cs` (delete the moved members, delegate to `MattersBlobs`)
- Modify: `RegExAzFunc/RegExAzFunc.sln`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `internal static class MattersBlobs` with:
    - `string DecodeStoragePath(string value)`
    - `bool TryResolveBlobName(string storagePath, out string blobName, out string error)`
    - `string InferContentType(string fileName)`
    - `string SanitizeFileName(string name)`
    - `string ContentDisposition(string disposition, string fileName)`
    - `bool IsMailBlob(string blobName)`
    - `BlobContainerClient GetContainer()` — throws `InvalidOperationException` when `MATTERS_STORAGE_CONNECTION` is unset

- [ ] **Step 1: Scaffold the test project**

```bash
cd C:/Development/REPO/RSE-Law
dotnet new xunit -o RegExAzFunc.Tests
dotnet add RegExAzFunc.Tests/RegExAzFunc.Tests.csproj reference RegExAzFunc/RegExAzFunc.csproj
dotnet sln RegExAzFunc/RegExAzFunc.sln add RegExAzFunc.Tests/RegExAzFunc.Tests.csproj
```

Then edit `RegExAzFunc.Tests/RegExAzFunc.Tests.csproj` so the `TargetFramework` is `net10.0`, matching `RegExAzFunc.csproj`, and add `<FrameworkReference Include="Microsoft.AspNetCore.App" />` inside an `ItemGroup` — the function project references ASP.NET types and the test project has to resolve them transitively.

`Company.Function` members are `internal`, so add this to `RegExAzFunc/RegExAzFunc.csproj` inside an `ItemGroup`:

```xml
<AssemblyAttribute Include="System.Runtime.CompilerServices.InternalsVisibleToAttribute">
  <_Parameter1>RegExAzFunc.Tests</_Parameter1>
</AssemblyAttribute>
```

- [ ] **Step 2: Write the failing characterization tests**

Create `RegExAzFunc.Tests/MattersBlobsTests.cs`. These assert the behaviour that exists today, so the refactor is provably behaviour-preserving. Delete the `dotnet new xunit` sample file `UnitTest1.cs` if present.

```csharp
using Company.Function;

namespace RegExAzFunc.Tests;

public class MattersBlobsTests
{
    [Fact]
    public void DecodeStoragePath_passes_a_plain_url_through()
    {
        const string url = "https://samatters.blob.core.windows.net/matters/120.057/Emails/a.eml";
        Assert.Equal(url, MattersBlobs.DecodeStoragePath(url));
    }

    [Fact]
    public void DecodeStoragePath_decodes_the_indexer_token_with_its_padding_digit()
    {
        // UrlTokenEncode: url-safe base64 plus a trailing count of stripped '=' padding.
        const string plain = "https://samatters.blob.core.windows.net/matters/a.eml";
        string b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(plain));
        int padding = b64.Length - b64.TrimEnd('=').Length;
        string token = b64.TrimEnd('=').Replace('+', '-').Replace('/', '_') + padding;

        Assert.Equal(plain, MattersBlobs.DecodeStoragePath(token));
    }

    [Theory]
    [InlineData("x")]           // too short
    [InlineData("abcd9")]       // padding digit out of range
    public void DecodeStoragePath_rejects_malformed_tokens(string value)
    {
        Assert.Throws<FormatException>(() => MattersBlobs.DecodeStoragePath(value));
    }

    [Fact]
    public void TryResolveBlobName_unescapes_the_name_inside_the_container()
    {
        bool ok = MattersBlobs.TryResolveBlobName(
            "https://samatters.blob.core.windows.net/matters/120.057/Emails/Re%20Hearing.eml",
            out string name, out string error);

        Assert.True(ok, error);
        Assert.Equal("120.057/Emails/Re Hearing.eml", name);
    }

    [Fact]
    public void TryResolveBlobName_refuses_a_path_outside_the_container()
    {
        bool ok = MattersBlobs.TryResolveBlobName(
            "https://samatters.blob.core.windows.net/other/secret.eml",
            out _, out string error);

        Assert.False(ok);
        Assert.Contains("outside the matters container", error);
    }

    [Theory]
    [InlineData("brief.pdf", "application/pdf")]
    [InlineData("notes.TXT", "text/plain")]
    [InlineData("message.eml", "message/rfc822")]
    [InlineData("thing.unknown", "application/octet-stream")]
    public void InferContentType_maps_by_extension(string file, string expected)
    {
        Assert.Equal(expected, MattersBlobs.InferContentType(file));
    }

    [Fact]
    public void SanitizeFileName_strips_quotes_newlines_and_separators()
    {
        Assert.Equal("a_b_c_d_e", MattersBlobs.SanitizeFileName("a\"b\rc\\d/e"));
    }

    [Fact]
    public void ContentDisposition_keeps_an_ascii_fallback_and_a_utf8_name()
    {
        // Accented subjects are common in this corpus and used to throw inside Kestrel.
        string value = MattersBlobs.ContentDisposition("attachment", "Intercambio de Información.eml");

        Assert.Contains("filename=\"Intercambio de Informaci?n.eml\"", value);
        Assert.Contains("filename*=UTF-8''", value);
        Assert.Contains("Informaci%C3%B3n", value);
    }

    [Fact]
    public void ContentDisposition_falls_back_when_nothing_ascii_survives()
    {
        string value = MattersBlobs.ContentDisposition("inline", "上級.pdf");
        Assert.Contains("filename=\"download\"", value);
    }

    [Theory]
    [InlineData("a/b.eml", true)]
    [InlineData("a/b.MSG", true)]
    [InlineData("a/b.pdf", false)]
    public void IsMailBlob_accepts_both_mail_extensions(string name, bool expected)
    {
        Assert.Equal(expected, MattersBlobs.IsMailBlob(name));
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
dotnet test RegExAzFunc.Tests
```

Expected: FAIL — compile errors, `MattersBlobs` does not exist.

- [ ] **Step 4: Create `MattersBlobs.cs`**

Move the implementations out of `EmlPreviewFunc.cs` verbatim, adding `TryResolveBlobName` and `GetContainer`, which are the parts `LoadBlobBytes` did inline.

```csharp
using Azure.Storage.Blobs;
using System.Text;
using System.Text.RegularExpressions;

namespace Company.Function;

/// <summary>
/// Blob plumbing shared by EmlPreviewFunc (single message) and MattersBrowseFunc
/// (listing and bulk download). Deliberately free of ASP.NET types: callers turn
/// the string errors into whatever result shape they serve, and these stay unit-testable.
/// </summary>
internal static class MattersBlobs
{
    internal const string ContainerName = "matters";

    internal static string ContainerBase
    {
        get
        {
            string b = Environment.GetEnvironmentVariable("MATTERS_CONTAINER_URL")
                ?? "https://samatters.blob.core.windows.net/matters/";
            return b.EndsWith('/') ? b : b + "/";
        }
    }

    /// <summary>Decodes the indexer's base64Encode key format
    /// (UrlTokenEncode: url-safe alphabet + trailing padding-count digit),
    /// or passes a plain URL through.</summary>
    internal static string DecodeStoragePath(string value)
    {
        if (value.StartsWith("http://") || value.StartsWith("https://"))
        {
            return value;
        }
        if (value.Length < 2) { throw new FormatException("Token too short."); }
        int padding = value[^1] - '0';
        if (padding < 0 || padding > 2) { throw new FormatException("Bad padding digit."); }
        string b64 = value[..^1].Replace('-', '+').Replace('_', '/') + new string('=', padding);
        return Encoding.UTF8.GetString(Convert.FromBase64String(b64));
    }

    /// <summary>Turns a storagePath into a blob name inside the matters container,
    /// refusing anything that points elsewhere.</summary>
    internal static bool TryResolveBlobName(string storagePath, out string blobName, out string error)
    {
        blobName = "";
        error = "";
        string blobUrl;
        try
        {
            blobUrl = DecodeStoragePath(storagePath);
        }
        catch (FormatException)
        {
            error = "storagePath is not a valid URL or base64 token.";
            return false;
        }

        string containerBase = ContainerBase;
        if (!blobUrl.StartsWith(containerBase, StringComparison.OrdinalIgnoreCase))
        {
            error = "storagePath is outside the matters container.";
            return false;
        }

        blobName = Uri.UnescapeDataString(blobUrl.Substring(containerBase.Length));
        return true;
    }

    internal static BlobContainerClient GetContainer()
    {
        string connectionString = Environment.GetEnvironmentVariable("MATTERS_STORAGE_CONNECTION") ?? "";
        if (string.IsNullOrEmpty(connectionString))
        {
            throw new InvalidOperationException("MATTERS_STORAGE_CONNECTION app setting is not configured.");
        }
        return new BlobContainerClient(connectionString, ContainerName);
    }

    /// <summary>True when the blob is a mail message rather than a loose document.</summary>
    internal static bool IsMailBlob(string blobName) =>
        blobName.EndsWith(".eml", StringComparison.OrdinalIgnoreCase) ||
        blobName.EndsWith(".msg", StringComparison.OrdinalIgnoreCase);

    /// <summary>Strips what would break the Content-Disposition header, and the
    /// path separators that would let a crafted attachment name suggest a
    /// directory to the browser.</summary>
    internal static string SanitizeFileName(string name) =>
        Regex.Replace(name, @"[""\r\n\\/]", "_");

    /// <summary>
    /// Builds a Content-Disposition value that survives a non-ASCII file name.
    /// HTTP header values are Latin-1; assigning one containing 'ó' or an en-dash throws
    /// inside Kestrel and the caller gets a bare 500. RFC 6266: an ASCII-only filename
    /// any client can read, plus filename* with the real UTF-8 name per RFC 5987.
    /// </summary>
    internal static string ContentDisposition(string disposition, string fileName)
    {
        string clean = SanitizeFileName(fileName);

        string ascii = Regex.Replace(clean, @"[^ -~]", "?");
        if (string.IsNullOrWhiteSpace(ascii.Replace("?", ""))) { ascii = "download"; }

        string encoded = Uri.EscapeDataString(clean);
        return $"{disposition}; filename=\"{ascii}\"; filename*=UTF-8''{encoded}";
    }

    internal static string InferContentType(string fileName)
    {
        string ext = Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "pdf" => "application/pdf",
            "png" => "image/png",
            "jpg" or "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "bmp" => "image/bmp",
            "tif" or "tiff" => "image/tiff",
            "txt" or "log" => "text/plain",
            "htm" or "html" => "text/html",
            "csv" => "text/csv",
            "doc" => "application/msword",
            "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls" => "application/vnd.ms-excel",
            "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt" => "application/vnd.ms-powerpoint",
            "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "zip" => "application/zip",
            "eml" => "message/rfc822",
            _ => "application/octet-stream"
        };
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
dotnet test RegExAzFunc.Tests
```

Expected: PASS, 16 tests (xunit counts each Theory case separately).

- [ ] **Step 6: Delegate from `EmlPreviewFunc`**

In `RegExAzFunc/EmlPreviewFunc.cs`:

1. Delete the now-duplicated members: `IsMailBlob`, `SanitizeFileName`, `ContentDisposition`, `InferContentType`, `DecodeStoragePath`.
2. Add `using static Company.Function.MattersBlobs;` so every existing call site — `IsMailBlob(...)`, `ContentDisposition(...)`, `InferContentType(...)` — compiles unchanged.
3. Replace the body of `LoadBlobBytes` with the shared resolution:

```csharp
    private async Task<(byte[]? Bytes, string? BlobName, IActionResult? Error)> LoadBlobBytes(string storagePath)
    {
        if (!MattersBlobs.TryResolveBlobName(storagePath, out string blobName, out string resolveError))
        {
            return (null, null, new BadRequestObjectResult(resolveError));
        }

        BlobContainerClient container;
        try
        {
            container = MattersBlobs.GetContainer();
        }
        catch (InvalidOperationException ex)
        {
            return (null, null, new ObjectResult(new { error = ex.Message }) { StatusCode = 500 });
        }

        try
        {
            using var stream = new MemoryStream();
            await container.GetBlobClient(blobName).DownloadToAsync(stream);
            return (stream.ToArray(), blobName, null);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 404)
        {
            return (null, null, new NotFoundObjectResult("The .eml blob was not found."));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed loading blob {BlobName}", blobName);
            return (null, null, new ObjectResult(new { error = ex.Message }) { StatusCode = 500 });
        }
    }
```

- [ ] **Step 7: Build and re-run the tests**

```bash
dotnet build RegExAzFunc/RegExAzFunc.csproj
dotnet test RegExAzFunc.Tests
```

Expected: build succeeds with no warnings about unused usings; all tests still PASS. The refactor is behaviour-preserving because the tests exercise the moved code directly.

- [ ] **Step 8: Commit**

```bash
git add RegExAzFunc/MattersBlobs.cs RegExAzFunc/EmlPreviewFunc.cs RegExAzFunc/RegExAzFunc.csproj RegExAzFunc/RegExAzFunc.sln RegExAzFunc.Tests
git commit -m "Extract the shared blob plumbing, and give the function app tests"
```

---

### Task 2: Preview a `.msg`

`.msg` outnumbers `.eml` in the container 362,523 to 334,612, and every one of them currently fails preview: `IsMailBlob` accepts `.msg`, then `MimeMessage.Load` cannot parse a compound file. This is live in search today and unavoidable once a tree invites the clicks.

**Files:**
- Modify: `RegExAzFunc/RegExAzFunc.csproj` (add MsgReader)
- Create: `RegExAzFunc/MsgProjection.cs`
- Create: `RegExAzFunc.Tests/MsgProjectionTests.cs`
- Modify: `RegExAzFunc/EmlPreviewFunc.cs`

**Interfaces:**
- Consumes: `MattersBlobs.IsMailBlob`, `MattersBlobs.InferContentType`, `MattersBlobs.ContentDisposition` (Task 1).
- Produces:
  - `internal sealed record MsgAttachment(string Name, byte[] Data)` with `long Size => Data.LongLength`
  - `internal interface IMsgMessage` — `Subject`, `From`, `To`, `Cc`, `Sent`, `BodyHtml`, `BodyText`, `Attachments`
  - `internal sealed class PreviewDto` — the JSON both preview paths return
  - `bool MsgProjection.LooksLikeCompoundFile(ReadOnlySpan<byte> bytes)`
  - `PreviewDto MsgProjection.ToPreview(IMsgMessage message, Func<string, string> sanitizeHtml)`
  - `IMsgMessage MsgProjection.Read(byte[] bytes)` — the MsgReader adapter

- [ ] **Step 1: Add the package**

```bash
dotnet add RegExAzFunc/RegExAzFunc.csproj package MsgReader
dotnet build RegExAzFunc/RegExAzFunc.csproj
```

Expected: restores and builds. (The ingest branch pins 6.1.0; matching it avoids a conflict when that branch merges.)

- [ ] **Step 2: Write the failing tests**

Create `RegExAzFunc.Tests/MsgProjectionTests.cs`. The projection is tested through a fake, because real `.msg` bytes from this container are client correspondence and must not enter the repo.

```csharp
using System.Text.Json;
using Company.Function;

namespace RegExAzFunc.Tests;

public class MsgProjectionTests
{
    private sealed class FakeMsg : IMsgMessage
    {
        public string Subject { get; init; } = "";
        public string From { get; init; } = "";
        public IReadOnlyList<string> To { get; init; } = Array.Empty<string>();
        public IReadOnlyList<string> Cc { get; init; } = Array.Empty<string>();
        public DateTimeOffset? Sent { get; init; }
        public string? BodyHtml { get; init; }
        public string BodyText { get; init; } = "";
        public IReadOnlyList<MsgAttachment> Attachments { get; init; } = Array.Empty<MsgAttachment>();
    }

    [Fact]
    public void LooksLikeCompoundFile_recognises_the_ole2_signature()
    {
        byte[] msg = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0x00, 0x00];
        Assert.True(MsgProjection.LooksLikeCompoundFile(msg));
    }

    [Fact]
    public void LooksLikeCompoundFile_rejects_mime_and_short_input()
    {
        Assert.False(MsgProjection.LooksLikeCompoundFile("From: a@b.com\r\n"u8));
        Assert.False(MsgProjection.LooksLikeCompoundFile([0xD0, 0xCF]));
    }

    [Fact]
    public void ToPreview_carries_the_headers_across()
    {
        var msg = new FakeMsg
        {
            Subject = "Re: Hearing",
            From = "Scott Dallas <dallas@rse-law.com>",
            To = ["Daniel Eisenberg <dan@rse-law.com>"],
            Cc = ["RSE Matters <matters@rse-law.com>"],
            Sent = new DateTimeOffset(2025, 3, 4, 17, 33, 58, TimeSpan.Zero),
            BodyText = "Holding off until Friday."
        };

        PreviewDto dto = MsgProjection.ToPreview(msg, html => html);

        Assert.Equal("Re: Hearing", dto.Subject);
        Assert.Equal("Scott Dallas <dallas@rse-law.com>", dto.From);
        Assert.Equal(["Daniel Eisenberg <dan@rse-law.com>"], dto.To);
        Assert.Equal(["RSE Matters <matters@rse-law.com>"], dto.Cc);
        Assert.Equal("2025-03-04T17:33:58.0000000+00:00", dto.Date);
        Assert.Equal("Holding off until Friday.", dto.TextBody);
        Assert.Null(dto.HtmlBody);
    }

    [Fact]
    public void ToPreview_sends_html_through_the_sanitizer()
    {
        var msg = new FakeMsg { BodyHtml = "<p onclick='x()'>hi</p>" };

        PreviewDto dto = MsgProjection.ToPreview(msg, html => html.Replace(" onclick='x()'", ""));

        Assert.Equal("<p>hi</p>", dto.HtmlBody);
    }

    [Fact]
    public void ToPreview_reports_attachment_names_and_sizes()
    {
        var msg = new FakeMsg
        {
            Attachments = [new MsgAttachment("brief.pdf", new byte[2048])]
        };

        PreviewDto dto = MsgProjection.ToPreview(msg, html => html);

        Assert.Single(dto.Attachments);
        Assert.Equal("brief.pdf", dto.Attachments[0].Name);
        Assert.Equal(2048, dto.Attachments[0].SizeBytes);
    }

    [Fact]
    public void ToPreview_leaves_an_undated_message_with_an_empty_date()
    {
        PreviewDto dto = MsgProjection.ToPreview(new FakeMsg(), html => html);
        Assert.Equal("", dto.Date);
    }

    [Fact]
    public void PreviewDto_serialises_with_the_keys_the_web_part_already_reads()
    {
        // IEmailItem.ts consumes these exact names; renaming one silently empties the pane.
        string json = JsonSerializer.Serialize(MsgProjection.ToPreview(new FakeMsg(), h => h));

        foreach (string key in new[] { "subject", "from", "to", "cc", "date", "htmlBody", "textBody", "attachments" })
        {
            Assert.Contains($"\"{key}\":", json);
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
dotnet test RegExAzFunc.Tests --filter MsgProjectionTests
```

Expected: FAIL — compile errors, `MsgProjection` and `IMsgMessage` do not exist.

- [ ] **Step 4: Create `MsgProjection.cs`**

```csharp
using System.Text.Json.Serialization;

namespace Company.Function;

internal sealed record MsgAttachment(string Name, byte[] Data)
{
    public long Size => Data.LongLength;
}

/// <summary>
/// The parts of a .msg this app needs, behind an interface so the projection is
/// testable without a real compound file. Real .msg bytes in this container are
/// client correspondence and are never committed as fixtures.
/// </summary>
internal interface IMsgMessage
{
    string Subject { get; }
    string From { get; }
    IReadOnlyList<string> To { get; }
    IReadOnlyList<string> Cc { get; }
    DateTimeOffset? Sent { get; }
    string? BodyHtml { get; }
    string BodyText { get; }
    IReadOnlyList<MsgAttachment> Attachments { get; }
}

internal sealed class PreviewAttachmentDto
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("sizeBytes")] public long SizeBytes { get; set; }
}

/// <summary>The preview JSON shape. Property names are pinned by attribute because
/// models/IEmailItem.ts reads them literally.</summary>
internal sealed class PreviewDto
{
    [JsonPropertyName("subject")] public string Subject { get; set; } = "";
    [JsonPropertyName("from")] public string From { get; set; } = "";
    [JsonPropertyName("to")] public string[] To { get; set; } = Array.Empty<string>();
    [JsonPropertyName("cc")] public string[] Cc { get; set; } = Array.Empty<string>();
    [JsonPropertyName("date")] public string Date { get; set; } = "";
    [JsonPropertyName("htmlBody")] public string? HtmlBody { get; set; }
    [JsonPropertyName("textBody")] public string TextBody { get; set; } = "";
    [JsonPropertyName("attachments")] public PreviewAttachmentDto[] Attachments { get; set; } = Array.Empty<PreviewAttachmentDto>();
}

internal static class MsgProjection
{
    private static ReadOnlySpan<byte> Ole2Signature => [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

    /// <summary>Detects a .msg by its OLE2 compound-file header rather than by extension.
    /// The ingest derived blob names from subjects, so an extension is not evidence.</summary>
    internal static bool LooksLikeCompoundFile(ReadOnlySpan<byte> bytes) =>
        bytes.Length >= 8 && bytes[..8].SequenceEqual(Ole2Signature);

    internal static PreviewDto ToPreview(IMsgMessage message, Func<string, string> sanitizeHtml)
    {
        return new PreviewDto
        {
            Subject = message.Subject,
            From = message.From,
            To = message.To.ToArray(),
            Cc = message.Cc.ToArray(),
            Date = message.Sent?.ToString("o") ?? "",
            HtmlBody = message.BodyHtml == null ? null : sanitizeHtml(message.BodyHtml),
            TextBody = message.BodyText,
            Attachments = message.Attachments
                .Select(a => new PreviewAttachmentDto { Name = a.Name, SizeBytes = a.Size })
                .ToArray()
        };
    }

    /// <summary>Adapter over MsgReader. Not unit-tested — it is a thin mapping onto a
    /// third-party parser, verified against real blobs through the local Functions host.</summary>
    internal static IMsgMessage Read(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes);
        using var message = new MsgReader.Outlook.Storage.Message(stream);

        var attachments = new List<MsgAttachment>();
        foreach (object obj in message.Attachments)
        {
            if (obj is MsgReader.Outlook.Storage.Attachment a && a.Data != null)
            {
                attachments.Add(new MsgAttachment(a.FileName ?? "attachment", a.Data));
            }
        }

        return new MsgReaderMessage
        {
            Subject = message.Subject ?? "",
            From = message.Sender?.DisplayName ?? message.Sender?.Email ?? "",
            To = message.GetEmailRecipients(MsgReader.Outlook.RecipientType.To, false, false) is string to && to.Length > 0
                 ? [to] : Array.Empty<string>(),
            Cc = message.GetEmailRecipients(MsgReader.Outlook.RecipientType.Cc, false, false) is string cc && cc.Length > 0
                 ? [cc] : Array.Empty<string>(),
            Sent = message.SentOn.HasValue ? new DateTimeOffset(message.SentOn.Value) : null,
            BodyHtml = string.IsNullOrWhiteSpace(message.BodyHtml) ? null : message.BodyHtml,
            BodyText = message.BodyText ?? "",
            Attachments = attachments
        };
    }

    private sealed class MsgReaderMessage : IMsgMessage
    {
        public string Subject { get; init; } = "";
        public string From { get; init; } = "";
        public IReadOnlyList<string> To { get; init; } = Array.Empty<string>();
        public IReadOnlyList<string> Cc { get; init; } = Array.Empty<string>();
        public DateTimeOffset? Sent { get; init; }
        public string? BodyHtml { get; init; }
        public string BodyText { get; init; } = "";
        public IReadOnlyList<MsgAttachment> Attachments { get; init; } = Array.Empty<MsgAttachment>();
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
dotnet test RegExAzFunc.Tests --filter MsgProjectionTests
```

Expected: PASS, 7 tests. If `Read` fails to compile, adjust only the MsgReader member names to match the installed version — the interface and projection above are what the tests pin.

- [ ] **Step 6: Route `.msg` through the projection in `ServePreview`**

In `EmlPreviewFunc.ServePreview`, after the existing loose-document branch and **before** `LoadMessage` is called, add:

```csharp
        if (MsgProjection.LooksLikeCompoundFile(docBytes!))
        {
            return new OkObjectResult(MsgProjection.ToPreview(MsgProjection.Read(docBytes!), Sanitize));
        }
```

`docBytes` is already in hand from the loose-document check above, so this costs no extra download.

- [ ] **Step 7: Serve attachments out of a `.msg` in `ServeAttachment`**

In `ServeAttachment`, after the `!IsMailBlob(rawName!)` branch and before `LoadMessage`, add:

```csharp
        if (MsgProjection.LooksLikeCompoundFile(rawBytes!))
        {
            IMsgMessage msg = MsgProjection.Read(rawBytes!);
            foreach (MsgAttachment att in msg.Attachments)
            {
                if (!string.Equals(att.Name, attachmentName, StringComparison.OrdinalIgnoreCase)) { continue; }

                string type = InferContentType(att.Name);
                string disposition = IsDownload(req) ? "attachment" : "inline";
                req.HttpContext.Response.Headers["Content-Disposition"] = ContentDisposition(disposition, att.Name);
                return new FileContentResult(att.Data, type);
            }
            return new NotFoundObjectResult($"Attachment '{attachmentName}' was not found in the message.");
        }
```

- [ ] **Step 8: Build, test, and verify against a real `.msg`**

```bash
dotnet build RegExAzFunc/RegExAzFunc.csproj
dotnet test RegExAzFunc.Tests
```

Then verify against real bytes, which the unit tests deliberately do not cover. Start the local host (`func start` in `RegExAzFunc`, with `MATTERS_STORAGE_CONNECTION` set in `local.settings.json`) and POST a real `.msg` path — pick one from the container:

```bash
az storage blob list --account-name samatters --container-name matters --auth-mode login \
  --prefix "120.057/Emails/" --num-results 5 --query "[?ends_with(name,'.msg')].name" -o tsv
```

```bash
curl -s -X POST http://localhost:7071/api/EmlPreviewFunc \
  -H 'Content-Type: application/json' \
  -d '{"storagePath":"https://samatters.blob.core.windows.net/matters/<name from above, URL-encoded>"}' \
  | head -c 600
```

Expected: JSON with a populated `subject`, `from` and `textBody` — not the `"This file is not a readable email message."` error. Record the blob name checked in the commit message; do not paste message content anywhere.

- [ ] **Step 9: Commit**

```bash
git add RegExAzFunc/MsgProjection.cs RegExAzFunc/EmlPreviewFunc.cs RegExAzFunc/RegExAzFunc.csproj RegExAzFunc.Tests/MsgProjectionTests.cs
git commit -m "Preview a .msg instead of failing to parse it as MIME"
```

---

### Task 3: `MattersBrowseFunc` — list one directory level

**Files:**
- Create: `RegExAzFunc/MattersBrowseFunc.cs`
- Create: `RegExAzFunc.Tests/BrowsePathsTests.cs`
- Create: `RegExAzFunc/BrowsePaths.cs`

**Interfaces:**
- Consumes: `MattersBlobs.ContainerBase`, `MattersBlobs.GetContainer` (Task 1).
- Produces:
  - `bool BrowsePaths.TryNormalizePrefix(string? raw, out string prefix, out string error)`
  - `string BrowsePaths.ClassifyKind(string blobName)` → `"eml" | "msg" | "attachment" | "other"`
  - `string BrowsePaths.LeafName(string nameOrPrefix)`
  - `string BrowsePaths.BlobUrl(string blobName)`
  - `MattersBrowseFunc` HTTP endpoint answering `op=list`

- [ ] **Step 1: Write the failing tests**

Create `RegExAzFunc.Tests/BrowsePathsTests.cs`:

```csharp
using Company.Function;

namespace RegExAzFunc.Tests;

public class BrowsePathsTests
{
    [Fact]
    public void TryNormalizePrefix_treats_empty_as_the_container_root()
    {
        Assert.True(BrowsePaths.TryNormalizePrefix(null, out string prefix, out _));
        Assert.Equal("", prefix);

        Assert.True(BrowsePaths.TryNormalizePrefix("", out prefix, out _));
        Assert.Equal("", prefix);
    }

    [Fact]
    public void TryNormalizePrefix_appends_the_trailing_delimiter()
    {
        Assert.True(BrowsePaths.TryNormalizePrefix("120.057/Emails", out string prefix, out _));
        Assert.Equal("120.057/Emails/", prefix);
    }

    [Fact]
    public void TryNormalizePrefix_leaves_an_already_terminated_prefix_alone()
    {
        Assert.True(BrowsePaths.TryNormalizePrefix("120.057/", out string prefix, out _));
        Assert.Equal("120.057/", prefix);
    }

    [Theory]
    [InlineData("/120.057/")]          // absolute
    [InlineData("../secrets/")]        // traversal
    [InlineData("120.057/../../x/")]   // traversal mid-path
    public void TryNormalizePrefix_refuses_paths_that_try_to_escape(string raw)
    {
        Assert.False(BrowsePaths.TryNormalizePrefix(raw, out _, out string error));
        Assert.NotEqual("", error);
    }

    [Theory]
    [InlineData("120.057/Emails/Attachments/kabc/brief.pdf", "attachment")]
    [InlineData("120.057/Emails/Re Hearing [kabc].eml", "eml")]
    [InlineData("120.057/Emails/Re Hearing [kabc].MSG", "msg")]
    [InlineData("120.057/Notes/scan.pdf", "other")]
    public void ClassifyKind_puts_attachments_first_then_falls_back_to_the_extension(string name, string expected)
    {
        Assert.Equal(expected, BrowsePaths.ClassifyKind(name));
    }

    [Fact]
    public void ClassifyKind_matches_the_attachments_segment_case_insensitively()
    {
        Assert.Equal("attachment", BrowsePaths.ClassifyKind("m/Emails/ATTACHMENTS/k1/a.pdf"));
    }

    [Fact]
    public void LeafName_takes_the_last_segment_of_a_blob_or_a_prefix()
    {
        Assert.Equal("brief.pdf", BrowsePaths.LeafName("120.057/Emails/Attachments/k1/brief.pdf"));
        Assert.Equal("Emails", BrowsePaths.LeafName("120.057/Emails/"));
        Assert.Equal("120.057", BrowsePaths.LeafName("120.057/"));
    }

    [Fact]
    public void BlobUrl_escapes_each_segment_but_keeps_the_separators()
    {
        string url = BrowsePaths.BlobUrl("120.057/Emails/Re Hearing.eml");
        Assert.Equal("https://samatters.blob.core.windows.net/matters/120.057/Emails/Re%20Hearing.eml", url);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
dotnet test RegExAzFunc.Tests --filter BrowsePathsTests
```

Expected: FAIL — `BrowsePaths` does not exist.

- [ ] **Step 3: Create `BrowsePaths.cs`**

```csharp
namespace Company.Function;

/// <summary>Prefix and name handling for the browse endpoints. Pure string work,
/// kept apart from the HTTP layer so it can be tested directly.</summary>
internal static class BrowsePaths
{
    internal static bool TryNormalizePrefix(string? raw, out string prefix, out string error)
    {
        prefix = "";
        error = "";
        if (string.IsNullOrWhiteSpace(raw)) { return true; }

        string value = raw.Replace('\\', '/');
        if (value.StartsWith('/'))
        {
            error = "prefix must be relative to the container root.";
            return false;
        }
        if (value.Split('/').Any(segment => segment == ".."))
        {
            error = "prefix must not contain '..'.";
            return false;
        }

        prefix = value.EndsWith('/') ? value : value + "/";
        return true;
    }

    /// <summary>Attachments are their own blobs under Attachments/&lt;token&gt;/, so the
    /// path decides before the extension does: a .pdf under Attachments is an attachment,
    /// and so is a .msg someone mailed as a file.</summary>
    internal static string ClassifyKind(string blobName)
    {
        if (blobName.Contains("/Attachments/", StringComparison.OrdinalIgnoreCase))
        {
            return "attachment";
        }
        if (blobName.EndsWith(".eml", StringComparison.OrdinalIgnoreCase)) { return "eml"; }
        if (blobName.EndsWith(".msg", StringComparison.OrdinalIgnoreCase)) { return "msg"; }
        return "other";
    }

    internal static string LeafName(string nameOrPrefix)
    {
        string trimmed = nameOrPrefix.TrimEnd('/');
        int slash = trimmed.LastIndexOf('/');
        return slash < 0 ? trimmed : trimmed[(slash + 1)..];
    }

    /// <summary>The full blob URL, which is the form every existing endpoint accepts
    /// as storagePath. Segments are escaped individually so '/' survives.</summary>
    internal static string BlobUrl(string blobName)
    {
        string escaped = string.Join('/', blobName.Split('/').Select(Uri.EscapeDataString));
        return MattersBlobs.ContainerBase + escaped;
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
dotnet test RegExAzFunc.Tests --filter BrowsePathsTests
```

Expected: PASS, 13 tests (xunit counts each Theory case separately).

- [ ] **Step 5: Create `MattersBrowseFunc.cs` with the list operation**

```csharp
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Company.Function;

/// <summary>
/// Browsing the matters container as a tree, for the Email Archive Search web part.
///
///   GET ?op=list&amp;prefix=&amp;cursor=   -> one directory level: child folders and files
///   GET ?op=probe&amp;prefix=             -> whether the folder is within the download cap
///   GET ?op=zip&amp;prefix=               -> that folder, streamed as a zip
///
/// The container holds ~965,000 blobs across 1,519 matter folders, and one folder
/// (UnsortedMatterCommunication) holds 201,356 of them. Nothing here may enumerate a
/// whole folder eagerly.
/// </summary>
public class MattersBrowseFunc
{
    internal const int PageSize = 500;
    internal const int RootPageSize = 1000;

    private readonly ILogger<MattersBrowseFunc> _logger;

    public MattersBrowseFunc(ILogger<MattersBrowseFunc> logger)
    {
        _logger = logger;
    }

    [Function("MattersBrowseFunc")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequest req)
    {
        string op = req.Query["op"].ToString();
        if (string.IsNullOrWhiteSpace(op)) { op = "list"; }

        if (!BrowsePaths.TryNormalizePrefix(req.Query["prefix"], out string prefix, out string prefixError))
        {
            return new BadRequestObjectResult(new { error = prefixError });
        }

        BlobContainerClient container;
        try
        {
            container = MattersBlobs.GetContainer();
        }
        catch (InvalidOperationException ex)
        {
            return new ObjectResult(new { error = ex.Message }) { StatusCode = 500 };
        }

        return op switch
        {
            "list" => await ListAsync(container, prefix, req.Query["cursor"].ToString()),
            _ => new BadRequestObjectResult(new { error = $"Unknown op '{op}'." })
        };
    }

    // ── op=list: one level ───────────────────────────────────────────────

    private async Task<IActionResult> ListAsync(BlobContainerClient container, string prefix, string? cursor)
    {
        int pageSize = prefix.Length == 0 ? RootPageSize : PageSize;
        var folders = new List<object>();
        var files = new List<object>();
        string? next = null;

        try
        {
            IAsyncEnumerable<Page<BlobHierarchyItem>> pages = container
                .GetBlobsByHierarchyAsync(delimiter: "/", prefix: prefix)
                .AsPages(string.IsNullOrEmpty(cursor) ? null : cursor, pageSize);

            await foreach (Page<BlobHierarchyItem> page in pages)
            {
                foreach (BlobHierarchyItem item in page.Values)
                {
                    if (item.IsPrefix)
                    {
                        folders.Add(new
                        {
                            name = BrowsePaths.LeafName(item.Prefix),
                            path = item.Prefix
                        });
                    }
                    else
                    {
                        // A directory placeholder: zero bytes, named exactly like its folder.
                        if (item.Blob.Name.EndsWith('/')) { continue; }
                        files.Add(new
                        {
                            name = BrowsePaths.LeafName(item.Blob.Name),
                            path = BrowsePaths.BlobUrl(item.Blob.Name),
                            sizeBytes = item.Blob.Properties.ContentLength ?? 0,
                            lastModified = item.Blob.Properties.LastModified?.ToString("o") ?? "",
                            kind = BrowsePaths.ClassifyKind(item.Blob.Name)
                        });
                    }
                }
                next = page.ContinuationToken;
                break;   // one page per request; the client asks for the next with the cursor
            }
        }
        catch (RequestFailedException ex)
        {
            _logger.LogError(ex, "Listing failed for prefix {Prefix}", prefix);
            return new ObjectResult(new { error = "Could not list that folder." }) { StatusCode = 502 };
        }

        return new OkObjectResult(new
        {
            prefix,
            folders,
            files,
            cursor = string.IsNullOrEmpty(next) ? null : next
        });
    }
}
```

- [ ] **Step 6: Build and verify against the live container**

```bash
dotnet build RegExAzFunc/RegExAzFunc.csproj
```

Start the local host (`func start` in `RegExAzFunc`), then:

```bash
curl -s "http://localhost:7071/api/MattersBrowseFunc?op=list" | head -c 400
curl -s "http://localhost:7071/api/MattersBrowseFunc?op=list&prefix=120.057/Emails/" | head -c 400
```

Expected: the first returns `folders` containing matter names (`01.002`, `120.057`, …) and a non-null `cursor`, since 1,519 exceeds the 1,000 root page size. The second returns `files` with `kind: "eml"` or `"msg"` entries whose `path` is a full `https://samatters…` URL.

Then the folder that has to work:

```bash
curl -s "http://localhost:7071/api/MattersBrowseFunc?op=list&prefix=UnsortedMatterCommunication/" -o /dev/null -w "%{time_total}s\n"
```

Expected: well under a second. It returns one page of 500, not 201,356 entries.

- [ ] **Step 7: Commit**

```bash
git add RegExAzFunc/BrowsePaths.cs RegExAzFunc/MattersBrowseFunc.cs RegExAzFunc.Tests/BrowsePathsTests.cs
git commit -m "List the matters container one directory level at a time"
```

---

### Task 4: `op=probe` — the early-exit cap walk

**Files:**
- Create: `RegExAzFunc/DownloadCap.cs`
- Create: `RegExAzFunc.Tests/DownloadCapTests.cs`
- Modify: `RegExAzFunc/MattersBrowseFunc.cs`

**Interfaces:**
- Consumes: `MattersBrowseFunc.Run`'s op dispatch (Task 3).
- Produces:
  - `internal readonly record struct BlobEntry(string Name, long Size)`
  - `internal readonly record struct CapResult(int Files, long Bytes, bool WithinLimit)`
  - `const int DownloadCap.MaxFiles = 2000`, `const long DownloadCap.MaxBytes = 2L * 1024 * 1024 * 1024`
  - `Task<CapResult> DownloadCap.MeasureAsync(IAsyncEnumerable<BlobEntry> entries)`

The cap rule is written **once**, over `IAsyncEnumerable`, so the code the tests pin is the
code production runs. A synchronous twin would leave the real walk untested.

- [ ] **Step 1: Write the failing tests**

Create `RegExAzFunc.Tests/DownloadCapTests.cs`. The last test is the point of the whole design: the walk must stop, not merely report.

```csharp
using Company.Function;

namespace RegExAzFunc.Tests;

public class DownloadCapTests
{
    private static async IAsyncEnumerable<BlobEntry> Entries(int count, long each)
    {
        await Task.CompletedTask;
        for (int i = 0; i < count; i++) { yield return new BlobEntry($"f{i}.eml", each); }
    }

    private static async IAsyncEnumerable<BlobEntry> One(string name, long size)
    {
        await Task.CompletedTask;
        yield return new BlobEntry(name, size);
    }

    [Fact]
    public async Task Measure_totals_a_small_folder()
    {
        CapResult result = await DownloadCap.MeasureAsync(Entries(3, 100));

        Assert.Equal(3, result.Files);
        Assert.Equal(300, result.Bytes);
        Assert.True(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_allows_exactly_the_file_limit()
    {
        CapResult result = await DownloadCap.MeasureAsync(Entries(DownloadCap.MaxFiles, 1));

        Assert.Equal(DownloadCap.MaxFiles, result.Files);
        Assert.True(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_refuses_one_file_past_the_limit()
    {
        CapResult result = await DownloadCap.MeasureAsync(Entries(DownloadCap.MaxFiles + 1, 1));

        Assert.Equal(DownloadCap.MaxFiles + 1, result.Files);
        Assert.False(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_refuses_on_bytes_even_when_the_file_count_is_tiny()
    {
        CapResult result = await DownloadCap.MeasureAsync(One("huge.pst", DownloadCap.MaxBytes + 1));

        Assert.Equal(1, result.Files);
        Assert.False(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_allows_exactly_the_byte_limit()
    {
        CapResult result = await DownloadCap.MeasureAsync(One("big.zip", DownloadCap.MaxBytes));
        Assert.True(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_stops_enumerating_once_it_is_over()
    {
        // UnsortedMatterCommunication holds 201,356 entries. If MeasureAsync ever enumerates
        // past the cap, this test hangs rather than fails - which is the failure we want
        // to be impossible in production.
        int yielded = 0;
        async IAsyncEnumerable<BlobEntry> endless()
        {
            await Task.CompletedTask;
            while (true) { yielded++; yield return new BlobEntry($"f{yielded}.eml", 1); }
        }

        CapResult result = await DownloadCap.MeasureAsync(endless());

        Assert.False(result.WithinLimit);
        Assert.Equal(DownloadCap.MaxFiles + 1, yielded);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
dotnet test RegExAzFunc.Tests --filter DownloadCapTests
```

Expected: FAIL — `DownloadCap` does not exist.

- [ ] **Step 3: Create `DownloadCap.cs`**

```csharp
namespace Company.Function;

internal readonly record struct BlobEntry(string Name, long Size);

/// <summary>Files and bytes counted so far, and whether the folder may be downloaded.
/// When WithinLimit is false the counts are lower bounds: the walk stopped early, so
/// the caller must say "more than N", never a total.</summary>
internal readonly record struct CapResult(int Files, long Bytes, bool WithinLimit);

internal static class DownloadCap
{
    internal const int MaxFiles = 2000;
    internal const long MaxBytes = 2L * 1024 * 1024 * 1024;

    /// <summary>Walks entries and stops the moment either limit is crossed, so checking
    /// a 201,356-entry folder costs the same as checking any other: 2,001 entries.</summary>
    internal static async Task<CapResult> MeasureAsync(IAsyncEnumerable<BlobEntry> entries)
    {
        int files = 0;
        long bytes = 0;

        await foreach (BlobEntry entry in entries)
        {
            files++;
            bytes += entry.Size;
            if (files > MaxFiles || bytes > MaxBytes)
            {
                return new CapResult(files, bytes, false);
            }
        }

        return new CapResult(files, bytes, true);
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
dotnet test RegExAzFunc.Tests --filter DownloadCapTests
```

Expected: PASS, 6 tests. If the last one hangs, `Measure` is not returning early — fix before continuing.

- [ ] **Step 5: Wire `op=probe` into the function**

In `MattersBrowseFunc`, add the case and the two methods. `EnumerateAsync` is the flat, recursive walk both `probe` and `zip` use.

```csharp
            "probe" => await ProbeAsync(container, prefix),
```

```csharp
    // ── op=probe: is this folder within the cap? ─────────────────────────

    private async Task<IActionResult> ProbeAsync(BlobContainerClient container, string prefix)
    {
        CapResult result = await MeasureAsync(container, prefix);
        return new OkObjectResult(new
        {
            files = result.Files,
            bytes = result.Bytes,
            withinLimit = result.WithinLimit,
            fileLimit = DownloadCap.MaxFiles,
            byteLimit = DownloadCap.MaxBytes
        });
    }

    /// <summary>Flat walk of everything under the prefix. The stopping rule lives in
    /// DownloadCap, which DownloadCapTests pins — this only supplies the entries, lazily,
    /// so abandoning the sequence early abandons the listing too.</summary>
    private static Task<CapResult> MeasureAsync(BlobContainerClient container, string prefix) =>
        DownloadCap.MeasureAsync(EnumerateAsync(container, prefix));

    private static async IAsyncEnumerable<BlobEntry> EnumerateAsync(BlobContainerClient container, string prefix)
    {
        await foreach (BlobItem blob in container.GetBlobsAsync(prefix: prefix))
        {
            if (blob.Name.EndsWith('/')) { continue; }   // directory placeholder
            yield return new BlobEntry(blob.Name, blob.Properties.ContentLength ?? 0);
        }
    }
```

- [ ] **Step 6: Build and verify both sides of the cap**

```bash
dotnet build RegExAzFunc/RegExAzFunc.csproj
```

With the local host running:

```bash
curl -s "http://localhost:7071/api/MattersBrowseFunc?op=probe&prefix=120.057/"
curl -s "http://localhost:7071/api/MattersBrowseFunc?op=probe&prefix=UnsortedMatterCommunication/" -w "\n%{time_total}s\n"
```

Expected: `120.057/` returns `withinLimit` per its real size; `UnsortedMatterCommunication/` returns `withinLimit:false` with `files:2001` **in about a second** — proof the walk stopped rather than counting 201,356.

- [ ] **Step 7: Commit**

```bash
git add RegExAzFunc/DownloadCap.cs RegExAzFunc/MattersBrowseFunc.cs RegExAzFunc.Tests/DownloadCapTests.cs
git commit -m "Answer whether a folder is small enough to download, without counting it all"
```

---

### Task 5: `op=zip` — stream the folder

**Files:**
- Create: `RegExAzFunc/ZipNaming.cs`
- Create: `RegExAzFunc.Tests/ZipNamingTests.cs`
- Modify: `RegExAzFunc/MattersBrowseFunc.cs`

**Interfaces:**
- Consumes: `MeasureAsync` and the op dispatch (Task 4), `MattersBlobs.ContentDisposition` (Task 1).
- Produces:
  - `string ZipNaming.EntryName(string prefix, string blobName)`
  - `string ZipNaming.ArchiveFileName(string prefix)`
  - `string ZipNaming.ErrorManifest(IReadOnlyList<string> skipped)`

- [ ] **Step 1: Write the failing tests**

Create `RegExAzFunc.Tests/ZipNamingTests.cs`:

```csharp
using Company.Function;

namespace RegExAzFunc.Tests;

public class ZipNamingTests
{
    [Fact]
    public void EntryName_is_relative_to_the_requested_folder()
    {
        Assert.Equal(
            "Emails/Re Hearing.eml",
            ZipNaming.EntryName("120.057/", "120.057/Emails/Re Hearing.eml"));
    }

    [Fact]
    public void EntryName_keeps_the_attachment_folders_so_the_zip_mirrors_the_archive()
    {
        Assert.Equal(
            "Emails/Attachments/k1/brief.pdf",
            ZipNaming.EntryName("120.057/", "120.057/Emails/Attachments/k1/brief.pdf"));
    }

    [Fact]
    public void EntryName_at_the_container_root_keeps_the_whole_path()
    {
        Assert.Equal("120.057/Emails/a.eml", ZipNaming.EntryName("", "120.057/Emails/a.eml"));
    }

    [Fact]
    public void EntryName_leaves_a_blob_outside_the_prefix_untouched()
    {
        // Defensive: a listing should never produce this, and silently trimming the wrong
        // number of characters would put the file somewhere surprising in the zip.
        Assert.Equal("other/a.eml", ZipNaming.EntryName("120.057/", "other/a.eml"));
    }

    [Fact]
    public void ArchiveFileName_names_the_zip_after_the_folder()
    {
        Assert.Equal("120.057.zip", ZipNaming.ArchiveFileName("120.057/"));
        Assert.Equal("Emails.zip", ZipNaming.ArchiveFileName("120.057/Emails/"));
    }

    [Fact]
    public void ArchiveFileName_falls_back_at_the_container_root()
    {
        Assert.Equal("matters.zip", ZipNaming.ArchiveFileName(""));
    }

    [Fact]
    public void ErrorManifest_lists_what_was_skipped()
    {
        string text = ZipNaming.ErrorManifest(["Emails/a.eml", "Emails/b.eml"]);

        Assert.Contains("2 file(s)", text);
        Assert.Contains("Emails/a.eml", text);
        Assert.Contains("Emails/b.eml", text);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
dotnet test RegExAzFunc.Tests --filter ZipNamingTests
```

Expected: FAIL — `ZipNaming` does not exist.

- [ ] **Step 3: Create `ZipNaming.cs`**

```csharp
using System.Text;

namespace Company.Function;

internal static class ZipNaming
{
    /// <summary>The path a blob takes inside the archive: relative to the folder that was
    /// asked for, so a zip of 120.057/ opens as Emails/... beside Emails/Attachments/...</summary>
    internal static string EntryName(string prefix, string blobName) =>
        prefix.Length > 0 && blobName.StartsWith(prefix, StringComparison.Ordinal)
            ? blobName[prefix.Length..]
            : blobName;

    internal static string ArchiveFileName(string prefix)
    {
        string leaf = BrowsePaths.LeafName(prefix);
        return string.IsNullOrEmpty(leaf) ? "matters.zip" : leaf + ".zip";
    }

    /// <summary>A blob can disappear between listing and reading. Once bytes are on the
    /// wire the status code is already sent, so the archive carries its own report.</summary>
    internal static string ErrorManifest(IReadOnlyList<string> skipped)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"{skipped.Count} file(s) could not be read and are missing from this archive.");
        sb.AppendLine("They were listed when the download started and unreadable moments later,");
        sb.AppendLine("usually because the blob was deleted in between.");
        sb.AppendLine();
        foreach (string name in skipped) { sb.AppendLine(name); }
        return sb.ToString();
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
dotnet test RegExAzFunc.Tests --filter ZipNamingTests
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Wire `op=zip` into the function**

Add `using System.IO.Compression;` at the top of `MattersBrowseFunc.cs`, then the case and the method:

```csharp
            "zip" => await ZipAsync(req, container, prefix),
```

```csharp
    // ── op=zip: the folder, streamed ─────────────────────────────────────

    private async Task<IActionResult> ZipAsync(HttpRequest req, BlobContainerClient container, string prefix)
    {
        CapResult cap = await MeasureAsync(container, prefix);
        if (!cap.WithinLimit)
        {
            // Counts are lower bounds here - the walk stopped at the cap. The client
            // renders "more than N", never these numbers as a total.
            return new ObjectResult(new
            {
                error = "That folder is too large to download in one archive.",
                files = cap.Files,
                bytes = cap.Bytes,
                fileLimit = DownloadCap.MaxFiles,
                byteLimit = DownloadCap.MaxBytes
            })
            { StatusCode = StatusCodes.Status413PayloadTooLarge };
        }

        HttpResponse response = req.HttpContext.Response;
        response.StatusCode = StatusCodes.Status200OK;
        response.ContentType = "application/zip";
        response.Headers["Content-Disposition"] =
            MattersBlobs.ContentDisposition("attachment", ZipNaming.ArchiveFileName(prefix));

        var skipped = new List<string>();
        await using (Stream body = response.BodyWriter.AsStream())
        using (var archive = new ZipArchive(body, ZipArchiveMode.Create, leaveOpen: true))
        {
            await foreach (BlobItem blob in container.GetBlobsAsync(prefix: prefix))
            {
                if (blob.Name.EndsWith('/')) { continue; }

                string entryName = ZipNaming.EntryName(prefix, blob.Name);
                try
                {
                    // Fastest, not Optimal: mail compresses, PDFs do not, and CPU is the
                    // scarce resource on a Consumption plan.
                    ZipArchiveEntry entry = archive.CreateEntry(entryName, CompressionLevel.Fastest);
                    await using Stream entryStream = entry.Open();
                    await using Stream blobStream = await container.GetBlobClient(blob.Name).OpenReadAsync();
                    await blobStream.CopyToAsync(entryStream);
                }
                catch (RequestFailedException ex)
                {
                    _logger.LogWarning(ex, "Skipping {BlobName} during zip of {Prefix}", blob.Name, prefix);
                    skipped.Add(entryName);
                }
            }

            if (skipped.Count > 0)
            {
                ZipArchiveEntry report = archive.CreateEntry("_download-errors.txt", CompressionLevel.Fastest);
                await using Stream reportStream = report.Open();
                await using var writer = new StreamWriter(reportStream);
                await writer.WriteAsync(ZipNaming.ErrorManifest(skipped));
            }
        }

        return new EmptyResult();   // the response has already been written
    }
```

- [ ] **Step 6: Build and verify against the live container**

```bash
dotnet build RegExAzFunc/RegExAzFunc.csproj
```

With the local host running, download a real matter folder and inspect the archive:

```bash
curl -s "http://localhost:7071/api/MattersBrowseFunc?op=zip&prefix=120.057/Emails/Attachments/" -o /tmp/att.zip -D -
unzip -l /tmp/att.zip | head -20
```

Expected: `Content-Type: application/zip`, a `Content-Disposition` naming `Attachments.zip`, and entries with paths relative to the requested folder. Then confirm the refusal:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:7071/api/MattersBrowseFunc?op=zip&prefix=UnsortedMatterCommunication/"
```

Expected: `413`, returned in about a second.

- [ ] **Step 7: Commit**

```bash
git add RegExAzFunc/ZipNaming.cs RegExAzFunc/MattersBrowseFunc.cs RegExAzFunc.Tests/ZipNamingTests.cs
git commit -m "Stream a folder as a zip, and say so when one is too large"
```

---

### Task 6: Client service and tree model

Pure TypeScript with jest coverage. No UI yet.

**Files:**
- Create: `…/src/webparts/outlookSearch/models/ITreeNode.ts`
- Create: `…/src/webparts/outlookSearch/models/ITreeNode.test.ts`
- Create: `…/src/webparts/outlookSearch/services/BlobBrowseService.ts`
- Create: `…/src/webparts/outlookSearch/services/BlobBrowseService.test.ts`

All paths below are relative to `OutlookSearchSPFxWebPart/outlook-search-spfx`.

**Interfaces:**
- Consumes: the `list` / `probe` / `zip` contract (Tasks 3–5).
- Produces:
  - `ITreeNode`, `TreeRowKind`, `IListPage`, `IProbeResult`
  - `flattenVisible(nodes: ITreeNode[]): ITreeRow[]`
  - `filterRoots(nodes: ITreeNode[], filter: string): ITreeNode[]`
  - `class BlobBrowseService { list(prefix, cursor?); probe(prefix); zipUrl(prefix); }`

- [ ] **Step 1: Write the failing model tests**

Create `src/webparts/outlookSearch/models/ITreeNode.test.ts`:

```typescript
import { ITreeNode, flattenVisible, filterRoots } from './ITreeNode';

function folder(name: string, extra?: Partial<ITreeNode>): ITreeNode {
  return { name, path: `${name}/`, kind: 'folder', expanded: false, ...extra };
}

function file(name: string): ITreeNode {
  return { name, path: `https://samatters.blob.core.windows.net/matters/${name}`, kind: 'eml' };
}

describe('flattenVisible', () => {
  it('shows only the roots when nothing is expanded', () => {
    const rows = flattenVisible([folder('120.057'), folder('95A.002')]);

    expect(rows.map((r) => r.node.name)).toEqual(['120.057', '95A.002']);
    expect(rows.every((r) => r.depth === 0)).toBe(true);
  });

  it('includes the children of an expanded folder, one level deeper', () => {
    const rows = flattenVisible([
      folder('120.057', { expanded: true, children: [folder('Emails'), file('note.eml')] })
    ]);

    expect(rows.map((r) => r.node.name)).toEqual(['120.057', 'Emails', 'note.eml']);
    expect(rows.map((r) => r.depth)).toEqual([0, 1, 1]);
  });

  it('hides the children of a collapsed folder that has already loaded them', () => {
    const rows = flattenVisible([
      folder('120.057', { expanded: false, children: [file('note.eml')] })
    ]);

    expect(rows).toHaveLength(1);
  });

  it('appends a "more" row when the folder has a cursor left', () => {
    const rows = flattenVisible([
      folder('Unsorted', { expanded: true, children: [file('a.eml')], cursor: 'abc' })
    ]);

    expect(rows[rows.length - 1].kind).toBe('more');
    expect(rows[rows.length - 1].depth).toBe(1);
  });

  it('does not append a "more" row to a fully loaded folder', () => {
    const rows = flattenVisible([
      folder('120.057', { expanded: true, children: [file('a.eml')] })
    ]);

    expect(rows.some((r) => r.kind === 'more')).toBe(false);
  });

  it('recurses through nested expansions', () => {
    const rows = flattenVisible([
      folder('120.057', {
        expanded: true,
        children: [folder('Emails', { expanded: true, children: [file('a.eml')] })]
      })
    ]);

    expect(rows.map((r) => r.depth)).toEqual([0, 1, 2]);
  });
});

describe('filterRoots', () => {
  const roots = [folder('120.057'), folder('120.027'), folder('95A.002')];

  it('returns everything for an empty filter', () => {
    expect(filterRoots(roots, '')).toHaveLength(3);
  });

  it('matches a substring anywhere in the name', () => {
    expect(filterRoots(roots, '120.').map((n) => n.name)).toEqual(['120.057', '120.027']);
  });

  it('ignores case', () => {
    expect(filterRoots(roots, '95a').map((n) => n.name)).toEqual(['95A.002']);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd OutlookSearchSPFxWebPart/outlook-search-spfx
npx heft test --clean
```

Expected: FAIL — cannot resolve `./ITreeNode`.

- [ ] **Step 3: Create `ITreeNode.ts`**

```typescript
/** What a row in the file tree can be. 'more' is the synthetic "Load more" row. */
export type TreeRowKind = 'folder' | 'eml' | 'msg' | 'attachment' | 'other' | 'more';

export interface ITreeNode {
  /** Folders: the blob prefix ('120.057/'). Files: the full blob URL, which is what
   *  EmlPreviewFunc accepts as storagePath. */
  path: string;
  name: string;
  kind: Exclude<TreeRowKind, 'more'>;
  sizeBytes?: number;
  lastModified?: string;
  /** Folders only. */
  expanded?: boolean;
  children?: ITreeNode[];
  /** Continuation token from the last list call; set means more children exist. */
  cursor?: string;
  loading?: boolean;
  error?: string;
}

export interface ITreeRow {
  node: ITreeNode;
  depth: number;
  kind: TreeRowKind;
}

export interface IListPage {
  prefix: string;
  folders: ITreeNode[];
  files: ITreeNode[];
  cursor?: string;
}

export interface IProbeResult {
  files: number;
  bytes: number;
  withinLimit: boolean;
  fileLimit: number;
  byteLimit: number;
}

/**
 * The visible rows, in order, for a virtualized list. Children of a collapsed folder
 * stay loaded but unrendered, so collapsing and re-expanding costs no round trip.
 */
export function flattenVisible(nodes: ITreeNode[]): ITreeRow[] {
  const rows: ITreeRow[] = [];

  const walk = (list: ITreeNode[], depth: number): void => {
    for (const node of list) {
      rows.push({ node, depth, kind: node.kind });
      if (node.kind !== 'folder' || !node.expanded) { continue; }
      if (node.children) { walk(node.children, depth + 1); }
      if (node.cursor) {
        rows.push({ node, depth: depth + 1, kind: 'more' });
      }
    }
  };

  walk(nodes, 0);
  return rows;
}

export function filterRoots(nodes: ITreeNode[], filter: string): ITreeNode[] {
  const needle = filter.trim().toLowerCase();
  if (!needle) { return nodes; }
  return nodes.filter((n) => n.name.toLowerCase().indexOf(needle) >= 0);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
npx heft test --clean
```

Expected: PASS, 9 tests.

- [ ] **Step 5: Write the failing service tests**

Create `src/webparts/outlookSearch/services/BlobBrowseService.test.ts`:

```typescript
import { BlobBrowseService } from './BlobBrowseService';

const BASE = 'https://fn.azurewebsites.net/api/MattersBrowseFunc?code=abc123';

function fakeHttp(payload: unknown, ok = true, status = 200): { get: jest.Mock } {
  return {
    get: jest.fn().mockResolvedValue({
      ok,
      status,
      json: () => Promise.resolve(payload)
    })
  };
}

describe('BlobBrowseService', () => {
  it('builds a zip url that appends to the existing function key', () => {
    const service = new BlobBrowseService(fakeHttp({}) as never, BASE);

    expect(service.zipUrl('120.057/')).toBe(`${BASE}&op=zip&prefix=120.057%2F`);
  });

  it('requests one level and maps folders and files into nodes', async () => {
    const http = fakeHttp({
      prefix: '120.057/',
      folders: [{ name: 'Emails', path: '120.057/Emails/' }],
      files: [{
        name: 'a.eml',
        path: 'https://samatters.blob.core.windows.net/matters/120.057/a.eml',
        sizeBytes: 12,
        lastModified: '2025-03-04T17:33:58.0000000+00:00',
        kind: 'eml'
      }],
      cursor: null
    });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('120.057/');

    expect(http.get).toHaveBeenCalledWith(
      `${BASE}&op=list&prefix=120.057%2F`,
      expect.anything()
    );
    expect(page.folders[0]).toEqual(
      expect.objectContaining({ name: 'Emails', path: '120.057/Emails/', kind: 'folder', expanded: false })
    );
    expect(page.files[0]).toEqual(expect.objectContaining({ name: 'a.eml', kind: 'eml', sizeBytes: 12 }));
    expect(page.cursor).toBeUndefined();
  });

  it('passes a cursor through when continuing a folder', async () => {
    const http = fakeHttp({ prefix: '', folders: [], files: [], cursor: 'next-token' });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('', 'abc');

    expect(http.get).toHaveBeenCalledWith(
      `${BASE}&op=list&prefix=&cursor=abc`,
      expect.anything()
    );
    expect(page.cursor).toBe('next-token');
  });

  it('throws with the status when listing fails', async () => {
    const service = new BlobBrowseService(fakeHttp({}, false, 502) as never, BASE);

    await expect(service.list('120.057/')).rejects.toThrow('HTTP 502');
  });

  it('reads a probe result', async () => {
    const http = fakeHttp({ files: 2001, bytes: 5, withinLimit: false, fileLimit: 2000, byteLimit: 10 });
    const service = new BlobBrowseService(http as never, BASE);

    const result = await service.probe('Unsorted/');

    expect(result.withinLimit).toBe(false);
    expect(result.files).toBe(2001);
  });
});
```

- [ ] **Step 6: Run the tests to verify they fail**

```bash
npx heft test --clean
```

Expected: FAIL — cannot resolve `./BlobBrowseService`.

- [ ] **Step 7: Create `BlobBrowseService.ts`**

```typescript
import { HttpClient } from '@microsoft/sp-http';
import { IListPage, IProbeResult, ITreeNode } from '../models/ITreeNode';

/**
 * Calls MattersBrowseFunc. The browse URL already carries the function key
 * (?code=...), which is why every parameter is appended with '&' — the same rule
 * downloadUrls.ts follows for the preview function.
 */
export class BlobBrowseService {
  public constructor(private readonly _http: HttpClient, private readonly _browseUrl: string) {}

  public async list(prefix: string, cursor?: string): Promise<IListPage> {
    let url = `${this._browseUrl}&op=list&prefix=${encodeURIComponent(prefix)}`;
    if (cursor) { url += `&cursor=${encodeURIComponent(cursor)}`; }

    const response = await this._http.get(url, HttpClient.configurations.v1);
    if (!response.ok) {
      throw new Error(`Could not list that folder (HTTP ${response.status})`);
    }
    const json = await response.json();

    return {
      prefix: typeof json.prefix === 'string' ? json.prefix : prefix,
      folders: (Array.isArray(json.folders) ? json.folders : []).map(
        (f: { name: string; path: string }): ITreeNode => ({
          name: f.name,
          path: f.path,
          kind: 'folder',
          expanded: false
        })
      ),
      files: (Array.isArray(json.files) ? json.files : []).map(
        (f: { name: string; path: string; sizeBytes: number; lastModified: string; kind: ITreeNode['kind'] }): ITreeNode => ({
          name: f.name,
          path: f.path,
          kind: f.kind,
          sizeBytes: f.sizeBytes,
          lastModified: f.lastModified
        })
      ),
      cursor: typeof json.cursor === 'string' && json.cursor ? json.cursor : undefined
    };
  }

  public async probe(prefix: string): Promise<IProbeResult> {
    const url = `${this._browseUrl}&op=probe&prefix=${encodeURIComponent(prefix)}`;
    const response = await this._http.get(url, HttpClient.configurations.v1);
    if (!response.ok) {
      throw new Error(`Could not check that folder (HTTP ${response.status})`);
    }
    const json = await response.json();
    return {
      files: Number(json.files) || 0,
      bytes: Number(json.bytes) || 0,
      withinLimit: json.withinLimit === true,
      fileLimit: Number(json.fileLimit) || 0,
      byteLimit: Number(json.byteLimit) || 0
    };
  }

  /** A navigation target, not a fetch: the zip streams and must not buffer in the page. */
  public zipUrl(prefix: string): string {
    return `${this._browseUrl}&op=zip&prefix=${encodeURIComponent(prefix)}`;
  }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
npx heft test --clean
```

Expected: PASS, 14 tests across both files.

- [ ] **Step 9: Commit**

```bash
git add src/webparts/outlookSearch/models/ITreeNode.ts src/webparts/outlookSearch/models/ITreeNode.test.ts src/webparts/outlookSearch/services/BlobBrowseService.ts src/webparts/outlookSearch/services/BlobBrowseService.test.ts
git commit -m "Add the tree model and the browse service behind it"
```

---

### Task 7: The `FileTree` pane

**Files:**
- Create: `…/components/FileTree.tsx`
- Create: `…/components/FileTree.test.tsx`
- Modify: `…/components/OutlookSearch.module.scss`

**Interfaces:**
- Consumes: `BlobBrowseService`, `ITreeNode`, `flattenVisible`, `filterRoots` (Task 6); `fileTypeIcon` and `fileTypeColor` exported from `EmailList.tsx`.
- Produces:
  - `formatSize(bytes: number): string`
  - `capMessage(result: IProbeResult): string`
  - `const FileTree: React.FC<IFileTreeProps>` with props `{ service, width, selectedPath, onSelectMessage, onDownloadFile }`

- [ ] **Step 1: Write the failing tests for the two pure helpers**

Create `src/webparts/outlookSearch/components/FileTree.test.tsx`. Only the pure helpers are unit-tested; the component itself is verified in the workbench in Task 8, because SPFx has no component-test harness configured.

```typescript
import { formatSize, capMessage } from './FileTree';

describe('formatSize', () => {
  it('uses bytes below a kilobyte', () => {
    expect(formatSize(512)).toBe('512 B');
  });

  it('rounds to one decimal in KB and MB', () => {
    expect(formatSize(2048)).toBe('2.0 KB');
    expect(formatSize(5 * 1024 * 1024)).toBe('5.0 MB');
  });

  it('handles a missing size as an empty string', () => {
    expect(formatSize(0)).toBe('');
  });
});

describe('capMessage', () => {
  it('never states a total the walk did not finish', () => {
    const message = capMessage({
      files: 2001, bytes: 0, withinLimit: false, fileLimit: 2000, byteLimit: 2147483648
    });

    expect(message).toContain('more than 2,000 files');
    expect(message).not.toContain('2001');
    expect(message).not.toContain('2,001');
  });

  it('reports a size refusal in gigabytes', () => {
    const message = capMessage({
      files: 10, bytes: 3221225472, withinLimit: false, fileLimit: 2000, byteLimit: 2147483648
    });

    expect(message).toContain('2.0 GB');
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd OutlookSearchSPFxWebPart/outlook-search-spfx
npx heft test --clean
```

Expected: FAIL — cannot resolve `./FileTree`.

- [ ] **Step 3: Create `FileTree.tsx`**

```typescript
import * as React from 'react';
import { List, Icon, IconButton, SearchBox, Spinner, SpinnerSize, MessageBar, MessageBarType, Dialog, DialogType, DialogFooter, PrimaryButton } from '@fluentui/react';
import { ITreeNode, ITreeRow, IProbeResult, flattenVisible, filterRoots } from '../models/ITreeNode';
import { BlobBrowseService } from '../services/BlobBrowseService';
import { fileTypeIcon, fileTypeColor } from './EmailList';
import styles from './OutlookSearch.module.scss';

export interface IFileTreeProps {
  service: BlobBrowseService;
  /** Pane width in px — controlled by the splitter in OutlookSearch. */
  width: number;
  selectedPath: string | undefined;
  /** An .eml or .msg was clicked: show it in the reading pane. */
  onSelectMessage: (path: string, name: string) => void;
  /** A file's download control (or an attachment row) was clicked. */
  onDownloadFile: (path: string) => void;
}

export function formatSize(bytes: number): string {
  if (!bytes) { return ''; }
  if (bytes < 1024) { return `${bytes} B`; }
  if (bytes < 1024 * 1024) { return `${(bytes / 1024).toFixed(1)} KB`; }
  if (bytes < 1024 * 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

/**
 * The refusal text. The probe stops counting at the cap, so its numbers are lower
 * bounds and must never be printed as totals.
 */
export function capMessage(result: IProbeResult): string {
  const limitFiles = result.fileLimit.toLocaleString();
  const limitSize = formatSize(result.byteLimit);
  return `This folder holds more than ${limitFiles} files or more than ${limitSize}, `
       + `which is too much for a single archive. Open a folder inside it and download that instead.`;
}

/** Replaces the node at `path` (a folder prefix) inside the tree, without mutating. */
function updateFolder(nodes: ITreeNode[], path: string, change: (node: ITreeNode) => ITreeNode): ITreeNode[] {
  return nodes.map((node) => {
    if (node.path === path) { return change(node); }
    if (node.children) { return { ...node, children: updateFolder(node.children, path, change) }; }
    return node;
  });
}

export const FileTree: React.FC<IFileTreeProps> = (props) => {
  const { service, width, selectedPath, onSelectMessage, onDownloadFile } = props;

  const [roots, setRoots] = React.useState<ITreeNode[]>([]);
  const [rootCursor, setRootCursor] = React.useState<string | undefined>(undefined);
  const [filter, setFilter] = React.useState('');
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | undefined>(undefined);
  const [refusal, setRefusal] = React.useState<string | undefined>(undefined);

  // Root level: 1,000 per page, so all 1,519 matters arrive in two calls.
  const loadRoots = React.useCallback((cursor?: string): void => {
    setLoading(true);
    service.list('', cursor)
      .then((page) => {
        setRoots((prev) => prev.concat(page.folders).concat(page.files));
        setRootCursor(page.cursor);
        setLoading(false);
      })
      .catch((err: Error) => { setError(err.message); setLoading(false); });
  }, [service]);

  React.useEffect(() => { loadRoots(); }, [loadRoots]);

  // Keep fetching root pages until the container root is complete; the filter box
  // is only honest once every matter is in hand.
  React.useEffect(() => {
    if (rootCursor && !loading) { loadRoots(rootCursor); }
  }, [rootCursor, loading, loadRoots]);

  const loadChildren = React.useCallback((node: ITreeNode, cursor?: string): void => {
    setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, loading: true })));
    service.list(node.path, cursor)
      .then((page) => {
        setRoots((prev) => updateFolder(prev, node.path, (n) => ({
          ...n,
          loading: false,
          expanded: true,
          children: (n.children || []).concat(page.folders).concat(page.files),
          cursor: page.cursor
        })));
      })
      .catch((err: Error) => {
        setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, loading: false, error: err.message })));
      });
  }, [service]);

  const toggleFolder = React.useCallback((node: ITreeNode): void => {
    if (!node.expanded && !node.children) { loadChildren(node); return; }
    setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, expanded: !n.expanded })));
  }, [loadChildren]);

  // Probe before navigating: a navigation answered with 413 shows the user nothing.
  const downloadFolder = React.useCallback((node: ITreeNode): void => {
    service.probe(node.path)
      .then((result) => {
        if (!result.withinLimit) { setRefusal(capMessage(result)); return; }
        window.location.href = service.zipUrl(node.path);
      })
      .catch((err: Error) => setRefusal(err.message));
  }, [service]);

  const visible = React.useMemo(
    () => flattenVisible(filterRoots(roots, filter)),
    [roots, filter]
  );

  const renderRow = (row?: ITreeRow): JSX.Element | null => {
    if (!row) { return null; }
    const { node, depth, kind } = row;
    const indent = { paddingLeft: 8 + depth * 16 };

    if (kind === 'more') {
      return (
        <div className={styles.treeMore} style={indent} onClick={() => loadChildren(node, node.cursor)}>
          {node.loading ? <Spinner size={SpinnerSize.xSmall} /> : `Load more — ${(node.children || []).length} shown so far`}
        </div>
      );
    }

    const isFolder = kind === 'folder';
    const onRowClick = (): void => {
      if (isFolder) { toggleFolder(node); }
      else if (kind === 'eml' || kind === 'msg') { onSelectMessage(node.path, node.name); }
      else { onDownloadFile(node.path); }
    };

    return (
      <div
        className={node.path === selectedPath ? `${styles.treeRow} ${styles.treeRowSelected}` : styles.treeRow}
        style={indent}
        onClick={onRowClick}
        role="treeitem"
        aria-expanded={isFolder ? node.expanded === true : undefined}
      >
        {isFolder
          ? <Icon className={styles.treeChevron} iconName={node.expanded ? 'ChevronDown' : 'ChevronRight'} />
          : <span className={styles.treeChevron} />}
        <Icon
          className={styles.treeIcon}
          iconName={isFolder ? 'FabricFolder' : fileTypeIcon(node.name)}
          style={{ color: isFolder ? '#c19c00' : fileTypeColor(node.name) }}
        />
        <span className={styles.treeName} title={node.name}>{node.name}</span>
        {!isFolder && <span className={styles.treeSize}>{formatSize(node.sizeBytes || 0)}</span>}
        <IconButton
          className={styles.treeDownload}
          iconProps={{ iconName: 'Download' }}
          title={isFolder ? `Download ${node.name} as a zip, attachments included` : `Download ${node.name}`}
          ariaLabel={isFolder ? `Download folder ${node.name}` : `Download ${node.name}`}
          onClick={(e) => {
            e.stopPropagation();   // the row click would preview or expand instead
            if (isFolder) { downloadFolder(node); } else { onDownloadFile(node.path); }
          }}
        />
      </div>
    );
  };

  return (
    <div className={styles.treePane} style={{ flex: `0 0 ${width}px` }}>
      <SearchBox
        className={styles.treeFilter}
        placeholder="Filter matters"
        value={filter}
        onChange={(_, value) => setFilter(value || '')}
        onClear={() => setFilter('')}
      />

      {error && <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>}

      <div className={styles.treeRows} role="tree">
        {loading && roots.length === 0
          ? <Spinner size={SpinnerSize.medium} label="Loading matters…" />
          : <List items={visible} onRenderCell={renderRow} />}
      </div>

      <Dialog
        hidden={!refusal}
        onDismiss={() => setRefusal(undefined)}
        dialogContentProps={{ type: DialogType.normal, title: 'Too large to download' }}
      >
        {refusal}
        <DialogFooter>
          <PrimaryButton onClick={() => setRefusal(undefined)} text="OK" />
        </DialogFooter>
      </Dialog>
    </div>
  );
};
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
npx heft test --clean
```

Expected: PASS, 5 new tests (19 total).

- [ ] **Step 5: Add the tree styles**

Append to `src/webparts/outlookSearch/components/OutlookSearch.module.scss`, following the file's existing variables (`$border`, `$text-primary`, `$outlook-blue`):

```scss
/* ── Left: file tree ─────────────────────────────────────── */

.treePane {
  display: flex;
  flex-direction: column;
  min-height: 0;
  border-right: 1px solid $border;
}

.treeFilter {
  margin: 8px;
}

.treeRows {
  flex: 1 1 auto;
  overflow-y: auto;
  min-height: 0;
}

.treeRow {
  display: flex;
  align-items: center;
  height: 28px;
  cursor: pointer;
  padding-right: 4px;
  white-space: nowrap;

  &:hover {
    background: #f3f2f1;
  }
}

.treeRowSelected {
  background: #e1efff;
}

.treeChevron {
  width: 16px;
  flex: 0 0 16px;
  font-size: 12px;
  color: #605e5c;
}

.treeIcon {
  flex: 0 0 16px;
  margin: 0 6px 0 2px;
  font-size: 14px;
}

.treeName {
  flex: 1 1 auto;
  overflow: hidden;
  text-overflow: ellipsis;
  font-size: 13px;
}

.treeSize {
  flex: 0 0 auto;
  margin-left: 8px;
  font-size: 11px;
  color: #605e5c;
}

.treeDownload {
  flex: 0 0 28px;
  height: 24px;
  width: 24px;
}

.treeMore {
  display: flex;
  align-items: center;
  height: 28px;
  cursor: pointer;
  font-size: 12px;
  color: $outlook-blue;

  &:hover {
    text-decoration: underline;
  }
}
```

- [ ] **Step 6: Commit**

```bash
git add src/webparts/outlookSearch/components/FileTree.tsx src/webparts/outlookSearch/components/FileTree.test.tsx src/webparts/outlookSearch/components/OutlookSearch.module.scss
git commit -m "Add the file tree pane over the matters container"
```

---

### Task 8: Wire the third pane, the property, and the docs

**Files:**
- Modify: `…/components/OutlookSearch.tsx`
- Modify: `…/components/IOutlookSearchProps.ts`
- Modify: `…/OutlookSearchWebPart.ts`
- Modify: `…/loc/mystrings.d.ts`
- Modify: `…/loc/en-us.js`
- Modify: `…/components/OutlookSearch.module.scss`
- Modify: `OutlookSearchSPFxWebPart/README.md`

**Interfaces:**
- Consumes: `FileTree` (Task 7), `BlobBrowseService` (Task 6), the existing `emlDownloadUrl` from `services/downloadUrls.ts`.
- Produces: the deployable web part.

- [ ] **Step 1: Add the property through the stack**

`IOutlookSearchProps.ts` — add below `emlPreviewUrl`:

```typescript
  /** MattersBrowseFunc endpoint incl. ?code= key; empty hides the file tree. */
  browseFuncUrl: string;
```

`OutlookSearchWebPart.ts` — add `browseFuncUrl: string;` to `IOutlookSearchWebPartProps`, pass `browseFuncUrl: this.properties.browseFuncUrl || ''` in `render()`, and add this field to the connection group after `emlPreviewUrl`:

```typescript
                PropertyPaneTextField('browseFuncUrl', {
                  label: strings.BrowseFuncUrlLabel,
                  description: strings.BrowseFuncUrlDescription,
                  placeholder: 'https://regexazfunc.azurewebsites.net/api/MattersBrowseFunc?code=...'
                }),
```

`loc/mystrings.d.ts` — add `BrowseFuncUrlLabel: string;` and `BrowseFuncUrlDescription: string;`.

`loc/en-us.js` — add:

```javascript
    "BrowseFuncUrlLabel": "File tree service URL",
    "BrowseFuncUrlDescription": "MattersBrowseFunc endpoint including its ?code= function key. Shows the storage account as a browsable tree; leave empty to hide the tree pane."
```

- [ ] **Step 2: Add the third pane to `OutlookSearch.tsx`**

Import the pieces:

```typescript
import { FileTree } from './FileTree';
import { BlobBrowseService } from '../services/BlobBrowseService';
import { emlDownloadUrl } from '../services/downloadUrls';
```

Add the width constants beside the existing ones:

```typescript
const TREE_WIDTH_KEY = 'rse-outlookSearch-treeWidth';
const TREE_WIDTH_DEFAULT = 280;
const TREE_WIDTH_MIN = 200;
```

Destructure `browseFuncUrl` from props, build the service, and hold the tree width:

```typescript
  const browseService = React.useMemo(
    () => new BlobBrowseService(httpClient, browseFuncUrl),
    [httpClient, browseFuncUrl]
  );

  const [treeWidth, setTreeWidth] = React.useState<number>(() => {
    const raw = window.localStorage.getItem(TREE_WIDTH_KEY);
    const n = raw ? parseInt(raw, 10) : NaN;
    return isNaN(n) ? TREE_WIDTH_DEFAULT : n;
  });
```

Add the two handlers. `handleSelectPath` reuses the existing preview flow, so a tree click and a search-result click land in exactly the same place:

```typescript
  // A tree row is a blob URL, not a search hit. Build the minimum IEmailItem the
  // reading pane needs and let handleSelect do the rest.
  const handleSelectPath = React.useCallback((path: string, name: string): void => {
    handleSelect({
      storagePath: path,
      fileName: name,
      from: '', to: '', cc: '', subject: name, date: '',
      snippetHtml: '', bodyPreview: '', attachmentNames: []
    });
  }, [handleSelect]);

  const handleDownloadPath = React.useCallback((path: string): void => {
    if (!emlPreviewUrl) { return; }
    window.location.href = emlDownloadUrl(emlPreviewUrl, path);
  }, [emlPreviewUrl]);
```

Add the tree's splitter handlers. The existing ones close over `setListWidth`, so the tree needs its own set. `panesRef` is the shared container, and the tree starts at its left edge, so the drag position is the raw offset:

```typescript
  const treeDraggingRef = React.useRef(false);

  const saveTreeWidth = React.useCallback((w: number): void => {
    try { window.localStorage.setItem(TREE_WIDTH_KEY, String(Math.round(w))); } catch { /* ignore */ }
  }, []);

  // The tree may take at most what it can leave the other two panes.
  const clampTreeWidth = React.useCallback((w: number, containerWidth: number): number => {
    const max = Math.max(TREE_WIDTH_MIN, containerWidth - LIST_WIDTH_MIN - READING_WIDTH_MIN);
    return Math.min(Math.max(w, TREE_WIDTH_MIN), max);
  }, []);

  const onTreeSplitterPointerDown = React.useCallback((e: React.PointerEvent<HTMLDivElement>): void => {
    treeDraggingRef.current = true;
    e.currentTarget.setPointerCapture(e.pointerId);
    e.preventDefault();
  }, []);

  const onTreeSplitterPointerMove = React.useCallback((e: React.PointerEvent<HTMLDivElement>): void => {
    if (!treeDraggingRef.current || !panesRef.current) { return; }
    const rect = panesRef.current.getBoundingClientRect();
    setTreeWidth(clampTreeWidth(e.clientX - rect.left, rect.width));
  }, [clampTreeWidth]);

  const onTreeSplitterPointerUp = React.useCallback((e: React.PointerEvent<HTMLDivElement>): void => {
    if (!treeDraggingRef.current) { return; }
    treeDraggingRef.current = false;
    e.currentTarget.releasePointerCapture(e.pointerId);
    setTreeWidth((w) => { saveTreeWidth(w); return w; });
  }, [saveTreeWidth]);

  const onTreeSplitterKeyDown = React.useCallback((e: React.KeyboardEvent<HTMLDivElement>): void => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') { return; }
    e.preventDefault();
    const delta = e.key === 'ArrowLeft' ? -16 : 16;
    const containerWidth = panesRef.current ? panesRef.current.getBoundingClientRect().width : 1200;
    setTreeWidth((w) => {
      const next = clampTreeWidth(w + delta, containerWidth);
      saveTreeWidth(next);
      return next;
    });
  }, [clampTreeWidth, saveTreeWidth]);
```

Then render the tree as the first child of `styles.panes`, before `EmailList`, with its own splitter:

```tsx
        {browseFuncUrl && (
          <>
            <FileTree
              service={browseService}
              width={treeWidth}
              selectedPath={selected ? selected.storagePath : undefined}
              onSelectMessage={handleSelectPath}
              onDownloadFile={handleDownloadPath}
            />
            <div
              className={styles.splitter}
              role="separator"
              aria-orientation="vertical"
              aria-label="Resize file tree"
              tabIndex={0}
              onPointerDown={onTreeSplitterPointerDown}
              onPointerMove={onTreeSplitterPointerMove}
              onPointerUp={onTreeSplitterPointerUp}
              onKeyDown={onTreeSplitterKeyDown}
            />
          </>
        )}
```

- [ ] **Step 3: Add the collapse breakpoint**

Append to `OutlookSearch.module.scss`. Three panes below ~1100px leaves the reading pane unreadable, so the tree hides itself and its splitter with it:

```scss
@media (max-width: 1100px) {
  .treePane,
  .treePane + .splitter {
    display: none;
  }
}
```

- [ ] **Step 4: Build and run the full test suite**

```bash
cd OutlookSearchSPFxWebPart/outlook-search-spfx
npx heft test --clean
npm run build
```

Expected: all tests PASS and the build produces `sharepoint/solution/outlook-search-spfx.sppkg` with no TypeScript or SCSS errors.

- [ ] **Step 5: Verify in the hosted workbench**

```bash
npm run start
```

Open the hosted workbench, set **File tree service URL** to the deployed `MattersBrowseFunc` endpoint with its `?code=` key, and confirm each behaviour from the spec:

1. The tree lists matter folders; typing `120.` in the filter narrows to those matters.
2. Expanding `120.057` → `Emails` lists messages; clicking an `.eml` renders it in the reading pane.
3. Clicking a `.msg` renders it too — this is the Task 2 fix reaching the UI.
4. Clicking an attachment row downloads the file.
5. A file row's download button saves that file; a folder's zips the folder, and the zip contains the `Attachments/` subtree.
6. The download button on `UnsortedMatterCommunication` shows the refusal dialog reading **"more than 2,000 files"**, and shows it promptly rather than hanging.
7. Narrowing the browser below 1100px hides the tree and leaves the two original panes usable.

- [ ] **Step 6: Update the README**

In `OutlookSearchSPFxWebPart/README.md`, extend the ASCII layout diagram with the tree pane, add `FileTree.tsx` and `BlobBrowseService.ts` to the solution-layout table, and add a **File tree service URL** row to the property table pointing at `MattersBrowseFunc`. Note in that row that the cap is 2,000 files / 2 GB per archive and that the function needs `MATTERS_STORAGE_CONNECTION` and `MATTERS_CONTAINER_URL`, exactly as `EmlPreviewFunc` does.

- [ ] **Step 7: Commit**

```bash
git add src/webparts/outlookSearch OutlookSearchSPFxWebPart/README.md
git commit -m "Show the archive as a third pane, and configure where it reads from"
```

---

## Deployment note

`MattersBrowseFunc` ships in the same function app as `EmlPreviewFunc`, so deployment is the existing zip-deploy of `RegExAzFunc` — no new app settings beyond the two that function already requires. Get the new function's key from the portal (or `az functionapp function keys list`) and paste the full URL, key included, into the web part's **File tree service URL** property.

using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using MimeKit;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Company.Function;

/// <summary>
/// Outlook-fidelity access to .eml files in the matters blob container,
/// used by the Email Archive Search SPFx web part.
///
///   POST { storagePath }               -> preview JSON (sanitized HTML body with
///                                         cid: images inlined, recipients,
///                                         attachment names/sizes)
///   GET  ?path=...&amp;att=name        -> streams the decoded attachment with its
///                                         real MIME type (inline disposition, so
///                                         the browser opens PDFs/images directly)
///   GET  ?path=...&amp;att=name&amp;dl=1 -> the same bytes with an attachment
///                                         disposition, so it saves instead
///   GET  ?path=...                     -> the original .eml itself, as a download.
///                                         Served as stored rather than re-serialised
///                                         from MimeKit, so the saved file is
///                                         byte-identical to the archived message and
///                                         opens in Outlook with its attachments and
///                                         headers intact.
/// </summary>
public class EmlPreviewFunc
{
    public class PreviewRequest
    {
        /// <summary>metadata_storage_path from the search index — either the
        /// URL-token base64 key or a plain https URL.</summary>
        [JsonPropertyName("storagePath")]
        public string? StoragePath { get; set; }
    }

    public class AttachmentInfo
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("sizeBytes")] public long SizeBytes { get; set; }
    }

    private readonly ILogger<EmlPreviewFunc> _logger;

    public EmlPreviewFunc(ILogger<EmlPreviewFunc> logger)
    {
        _logger = logger;
    }

    [Function("EmlPreviewFunc")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get", "post")] HttpRequest req)
    {
        if (HttpMethods.IsGet(req.Method))
        {
            // no 'att' means the caller wants the message itself
            return string.IsNullOrWhiteSpace(req.Query["att"])
                ? await ServeEml(req)
                : await ServeAttachment(req);
        }
        return await ServePreview(req);
    }

    // ── POST: preview JSON ───────────────────────────────────────────────

    private async Task<IActionResult> ServePreview(HttpRequest req)
    {
        string body = await new StreamReader(req.Body).ReadToEndAsync();
        PreviewRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<PreviewRequest>(body);
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult("Malformed JSON payload.");
        }

        if (string.IsNullOrWhiteSpace(request?.StoragePath))
        {
            return new BadRequestObjectResult("Provide 'storagePath'.");
        }

        // A loose document (an attachment indexed in its own right) is not an email and must
        // not be run through MimeKit. Describe it instead, and list it as its own single
        // attachment so the reading pane's existing open/download controls work on it.
        var (docBytes, docName, docError) = await LoadBlobBytes(request.StoragePath);
        if (docError != null) { return docError; }
        if (!IsMailBlob(docName!))
        {
            string file = Path.GetFileName(docName!);
            return new OkObjectResult(new
            {
                subject = file,
                from = "",
                to = Array.Empty<string>(),
                cc = Array.Empty<string>(),
                date = "",
                htmlBody = (string?)null,
                textBody = $"{file} is an attachment saved with an archived message. "
                         + "Use the control above to open or download it.",
                attachments = new[] { new AttachmentInfo { Name = file, SizeBytes = docBytes!.LongLength } }
            });
        }

        var (message, _, error) = await LoadMessage(request.StoragePath);
        if (error != null) { return error; }

        string? html = message!.HtmlBody;
        if (html != null)
        {
            html = InlineCidImages(html, message);
            html = Sanitize(html);
        }

        var attachments = new List<AttachmentInfo>();
        foreach (MimeEntity entity in message.Attachments)
        {
            string? name = entity.ContentDisposition?.FileName ?? entity.ContentType?.Name;
            if (string.IsNullOrWhiteSpace(name)) { continue; }
            long size = 0;
            if (entity is MimePart part && part.Content != null)
            {
                using var counter = new MemoryStream();
                part.Content.DecodeTo(counter);
                size = counter.Length;
            }
            attachments.Add(new AttachmentInfo { Name = name, SizeBytes = size });
        }

        return new OkObjectResult(new
        {
            subject = message.Subject ?? "",
            from = message.From.ToString(),
            to = message.To.Select(a => a.ToString()).ToArray(),
            cc = message.Cc.Select(a => a.ToString()).ToArray(),
            date = message.Date.ToString("o"),
            htmlBody = html,
            textBody = message.TextBody ?? "",
            attachments
        });
    }

    // ── GET: stream one attachment by its real MIME type ─────────────────

    private async Task<IActionResult> ServeAttachment(HttpRequest req)
    {
        string? storagePath = req.Query["path"];
        string? attachmentName = req.Query["att"];
        if (string.IsNullOrWhiteSpace(storagePath) || string.IsNullOrWhiteSpace(attachmentName))
        {
            return new BadRequestObjectResult("Provide 'path' and 'att' query parameters.");
        }

        // When the blob IS the attachment, there is no message to search inside - serve it.
        var (rawBytes, rawName, rawError) = await LoadBlobBytes(storagePath);
        if (rawError != null) { return rawError; }
        if (!IsMailBlob(rawName!))
        {
            string file = Path.GetFileName(rawName!);
            if (!string.Equals(file, attachmentName, StringComparison.OrdinalIgnoreCase))
            {
                return new NotFoundObjectResult($"'{attachmentName}' was not found.");
            }
            req.HttpContext.Response.Headers["Content-Disposition"] = ContentDisposition(IsDownload(req) ? "attachment" : "inline", file);
            return new FileContentResult(rawBytes!, InferContentType(file));
        }

        var (message, _, error) = await LoadMessage(storagePath);
        if (error != null) { return error; }

        foreach (MimeEntity entity in message!.Attachments)
        {
            string? name = entity.ContentDisposition?.FileName ?? entity.ContentType?.Name;
            if (!string.Equals(name, attachmentName, StringComparison.OrdinalIgnoreCase)) { continue; }
            if (entity is not MimePart part || part.Content == null) { continue; }

            using var ms = new MemoryStream();
            part.Content.DecodeTo(ms);

            string contentType = part.ContentType?.MimeType ?? "";
            if (string.IsNullOrEmpty(contentType) || contentType == "application/octet-stream")
            {
                contentType = InferContentType(attachmentName);
            }

            // inline (the default) so the browser opens what it can render — PDF,
            // images, text — in the tab and downloads the rest by name. dl=1 forces
            // the save-file path for the explicit download control in the web part.
            string disposition = IsDownload(req) ? "attachment" : "inline";
            req.HttpContext.Response.Headers["Content-Disposition"] = ContentDisposition(disposition, attachmentName);
            return new FileContentResult(ms.ToArray(), contentType);
        }

        return new NotFoundObjectResult($"Attachment '{attachmentName}' was not found in the message.");
    }

    // ── GET: the original .eml, as a download ────────────────────────────

    private async Task<IActionResult> ServeEml(HttpRequest req)
    {
        string? storagePath = req.Query["path"];
        if (string.IsNullOrWhiteSpace(storagePath))
        {
            return new BadRequestObjectResult("Provide a 'path' query parameter.");
        }

        var (bytes, blobName, error) = await LoadBlobBytes(storagePath);
        if (error != null) { return error; }

        // The stored bytes, not a MimeKit round-trip: re-serialising can normalise
        // headers and re-encode parts, and this file is the firm's archived copy of
        // the message. It should be exactly what was received.
        string fileName = Path.GetFileName(blobName!);
        if (string.IsNullOrWhiteSpace(fileName)) { fileName = "message.eml"; }

        // Only a mail blob gets the .eml treatment. Appending it unconditionally used to hand
        // back "Mediation Brief.doc.eml" - a Word document renamed to something Outlook would
        // try to open as a message.
        if (!IsMailBlob(fileName))
        {
            req.HttpContext.Response.Headers["Content-Disposition"] = ContentDisposition("attachment", fileName);
            return new FileContentResult(bytes!, InferContentType(fileName));
        }

        req.HttpContext.Response.Headers["Content-Disposition"] = ContentDisposition("attachment", fileName);
        return new FileContentResult(bytes!, "message/rfc822");
    }

    private static bool IsDownload(HttpRequest req)
    {
        string? dl = req.Query["dl"];
        return !string.IsNullOrEmpty(dl) && dl != "0" && !string.Equals(dl, "false", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Strips what would break the Content-Disposition header, and the
    /// path separators that would let a crafted attachment name suggest a
    /// directory to the browser.</summary>
    internal static string SanitizeFileName(string name) =>
        Regex.Replace(name, @"[""\r\n\\/]", "_");

    /// <summary>
    /// Builds a Content-Disposition value that survives a non-ASCII file name.
    /// <para>
    /// HTTP header values are Latin-1. Assigning one containing 'ó' or an en-dash throws
    /// inside Kestrel, the exception escapes the function, and the caller gets a bare 500
    /// with an empty body - which is what the archive was doing to every message whose
    /// subject had an accent or an Outlook-autocorrected dash. Spanish party names and
    /// en-dashes are common in this corpus, so this was a large share of all downloads:
    /// "109.108 Huey Samuel Napier v. Daniel Tile Inc. et al. - Intercambio de Información.eml"
    /// failed every time while its plain-ASCII neighbours worked.
    /// </para>
    /// <para>
    /// RFC 6266: send an ASCII-only <c>filename</c> that any client can read, plus
    /// <c>filename*</c> with the real UTF-8 name percent-encoded per RFC 5987. Every current
    /// browser prefers <c>filename*</c>, so the saved file keeps its accents.
    /// </para>
    /// </summary>
    internal static string ContentDisposition(string disposition, string fileName)
    {
        string clean = SanitizeFileName(fileName);

        // '?' rather than dropping the character, so the fallback keeps the name's shape for
        // any client old enough to ignore filename*.
        string ascii = Regex.Replace(clean, @"[^ -~]", "?");
        if (string.IsNullOrWhiteSpace(ascii.Replace("?", ""))) { ascii = "download"; }

        string encoded = Uri.EscapeDataString(clean);
        return $"{disposition}; filename=\"{ascii}\"; filename*=UTF-8''{encoded}";
    }

    // ── Shared blob/MIME plumbing ────────────────────────────────────────

    /// <summary>
    /// True when the blob is a mail message rather than a loose document.
    /// <para>
    /// The indexer's indexedFileNameExtensions covers .pdf, .docx, .htm and the rest, because
    /// attachments are stored as their own blobs and the firm wants their contents searchable.
    /// That means an attachment is its own document in the index, and the web part will happily
    /// hand one of those to this function as if it were an email.
    /// </para>
    /// </summary>
    internal static bool IsMailBlob(string blobName) =>
        blobName.EndsWith(".eml", StringComparison.OrdinalIgnoreCase) ||
        blobName.EndsWith(".msg", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Parses the blob as MIME.
    /// <para>
    /// MimeMessage.Load used to be called unguarded, so a PDF - or any .eml truncated or
    /// corrupted in storage - threw out of the function and the host returned a bare 500 with
    /// an empty body. From the reading pane that surfaced as an unexplained Azure error on some
    /// search results and not others, with nothing to distinguish them beforehand.
    /// </para>
    /// </summary>
    private async Task<(MimeMessage? Message, string? BlobName, IActionResult? Error)> LoadMessage(string storagePath)
    {
        var (bytes, blobName, error) = await LoadBlobBytes(storagePath);
        if (error != null) { return (null, null, error); }

        using var stream = new MemoryStream(bytes!);
        try
        {
            return (MimeMessage.Load(stream), blobName, null);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Blob {BlobName} is not parseable as a MIME message", blobName);
            return (null, blobName, new ObjectResult(new
            {
                error = "This file is not a readable email message.",
                blob = Path.GetFileName(blobName)
            })
            { StatusCode = StatusCodes.Status415UnsupportedMediaType });
        }
    }

    /// <summary>Fetches the raw blob and the name it is stored under. Separate from
    /// LoadMessage because the .eml download must serve the stored bytes rather than
    /// a MimeKit re-serialisation of them.</summary>
    private async Task<(byte[]? Bytes, string? BlobName, IActionResult? Error)> LoadBlobBytes(string storagePath)
    {
        string blobUrl;
        try
        {
            blobUrl = DecodeStoragePath(storagePath);
        }
        catch (FormatException)
        {
            return (null, null, new BadRequestObjectResult("storagePath is not a valid URL or base64 token."));
        }

        string containerBase = Environment.GetEnvironmentVariable("MATTERS_CONTAINER_URL")
            ?? "https://samatters.blob.core.windows.net/matters/";
        if (!containerBase.EndsWith('/')) { containerBase += "/"; }
        if (!blobUrl.StartsWith(containerBase, StringComparison.OrdinalIgnoreCase))
        {
            // Only serve blobs from the matters container, nothing else.
            return (null, null, new BadRequestObjectResult("storagePath is outside the matters container."));
        }

        string connectionString = Environment.GetEnvironmentVariable("MATTERS_STORAGE_CONNECTION") ?? "";
        if (string.IsNullOrEmpty(connectionString))
        {
            return (null, null, new ObjectResult(new { error = "MATTERS_STORAGE_CONNECTION app setting is not configured." }) { StatusCode = 500 });
        }

        string blobName = Uri.UnescapeDataString(blobUrl.Substring(containerBase.Length));

        try
        {
            var container = new BlobContainerClient(connectionString, "matters");
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

    /// <summary>Replaces cid: references with data: URIs so inline images
    /// (signature logos etc.) render exactly as they do in Outlook.</summary>
    private static string InlineCidImages(string html, MimeMessage message)
    {
        foreach (MimePart part in message.BodyParts.OfType<MimePart>())
        {
            if (string.IsNullOrEmpty(part.ContentId) || part.Content == null) { continue; }
            using var ms = new MemoryStream();
            part.Content.DecodeTo(ms);
            string dataUri = $"data:{part.ContentType.MimeType};base64,{Convert.ToBase64String(ms.ToArray())}";
            html = html.Replace($"cid:{part.ContentId.Trim('<', '>')}", dataUri);
        }
        return html;
    }

    /// <summary>Defense-in-depth scrub of active content. The web part also
    /// renders the result inside a sandboxed iframe that blocks scripts.</summary>
    private static string Sanitize(string html)
    {
        html = Regex.Replace(html, @"<script\b[^>]*>[\s\S]*?</script\s*>", "", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"<(iframe|object|embed|form)\b[^>]*>[\s\S]*?</\1\s*>", "", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"<(iframe|object|embed|form|meta|base)\b[^>]*/?>", "", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"\son\w+\s*=\s*(""[^""]*""|'[^']*'|[^\s>]+)", "", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"(href|src)\s*=\s*([""']?)\s*javascript:[^""'>\s]*\2", "$1=$2#$2", RegexOptions.IgnoreCase);
        return html;
    }
}


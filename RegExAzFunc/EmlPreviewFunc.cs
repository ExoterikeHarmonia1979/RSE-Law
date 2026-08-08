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
///   POST { storagePath }            -> preview JSON (sanitized HTML body with
///                                      cid: images inlined, recipients,
///                                      attachment names/sizes)
///   GET  ?path=...&amp;att=name     -> streams the decoded attachment with its
///                                      real MIME type (inline disposition, so
///                                      the browser opens PDFs/images directly)
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
            return await ServeAttachment(req);
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

        var (message, error) = await LoadMessage(request.StoragePath);
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

        var (message, error) = await LoadMessage(storagePath);
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

            // inline (not attachment) so the browser opens what it can render
            // (PDF, images, text) in the tab and downloads the rest by name.
            string safeName = Regex.Replace(attachmentName, @"[""\r\n\\]", "_");
            req.HttpContext.Response.Headers["Content-Disposition"] = $"inline; filename=\"{safeName}\"";
            return new FileContentResult(ms.ToArray(), contentType);
        }

        return new NotFoundObjectResult($"Attachment '{attachmentName}' was not found in the message.");
    }

    // ── Shared blob/MIME plumbing ────────────────────────────────────────

    private async Task<(MimeMessage? Message, IActionResult? Error)> LoadMessage(string storagePath)
    {
        string blobUrl;
        try
        {
            blobUrl = DecodeStoragePath(storagePath);
        }
        catch (FormatException)
        {
            return (null, new BadRequestObjectResult("storagePath is not a valid URL or base64 token."));
        }

        string containerBase = Environment.GetEnvironmentVariable("MATTERS_CONTAINER_URL")
            ?? "https://samatters.blob.core.windows.net/matters/";
        if (!containerBase.EndsWith('/')) { containerBase += "/"; }
        if (!blobUrl.StartsWith(containerBase, StringComparison.OrdinalIgnoreCase))
        {
            // Only serve blobs from the matters container, nothing else.
            return (null, new BadRequestObjectResult("storagePath is outside the matters container."));
        }

        string connectionString = Environment.GetEnvironmentVariable("MATTERS_STORAGE_CONNECTION") ?? "";
        if (string.IsNullOrEmpty(connectionString))
        {
            return (null, new ObjectResult(new { error = "MATTERS_STORAGE_CONNECTION app setting is not configured." }) { StatusCode = 500 });
        }

        string blobName = Uri.UnescapeDataString(blobUrl.Substring(containerBase.Length));

        try
        {
            var container = new BlobContainerClient(connectionString, "matters");
            using var stream = new MemoryStream();
            await container.GetBlobClient(blobName).DownloadToAsync(stream);
            stream.Position = 0;
            return (MimeMessage.Load(stream), null);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 404)
        {
            return (null, new NotFoundObjectResult("The .eml blob was not found."));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed loading blob {BlobName}", blobName);
            return (null, new ObjectResult(new { error = ex.Message }) { StatusCode = 500 });
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

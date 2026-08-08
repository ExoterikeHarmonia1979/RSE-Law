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
/// Returns an Outlook-fidelity preview of an .eml stored in the matters blob
/// container: sanitized HTML body (inline cid: images embedded as data URIs),
/// plain-text fallback, recipients, and attachment names/sizes.
/// Called by the Email Archive Search SPFx web part.
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
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequest req)
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

        string blobUrl;
        try
        {
            blobUrl = DecodeStoragePath(request.StoragePath);
        }
        catch (FormatException)
        {
            return new BadRequestObjectResult("storagePath is not a valid URL or base64 token.");
        }

        string containerBase = Environment.GetEnvironmentVariable("MATTERS_CONTAINER_URL")
            ?? "https://samatters.blob.core.windows.net/matters/";
        if (!containerBase.EndsWith('/')) { containerBase += "/"; }
        if (!blobUrl.StartsWith(containerBase, StringComparison.OrdinalIgnoreCase))
        {
            // Only serve blobs from the matters container, nothing else.
            return new BadRequestObjectResult("storagePath is outside the matters container.");
        }

        string connectionString = Environment.GetEnvironmentVariable("MATTERS_STORAGE_CONNECTION") ?? "";
        if (string.IsNullOrEmpty(connectionString))
        {
            return new ObjectResult(new { error = "MATTERS_STORAGE_CONNECTION app setting is not configured." }) { StatusCode = 500 };
        }

        string blobName = Uri.UnescapeDataString(blobUrl.Substring(containerBase.Length));

        try
        {
            var container = new BlobContainerClient(connectionString, "matters");
            using var stream = new MemoryStream();
            await container.GetBlobClient(blobName).DownloadToAsync(stream);
            stream.Position = 0;

            var message = MimeMessage.Load(stream);

            string? html = message.HtmlBody;
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
        catch (Azure.RequestFailedException ex) when (ex.Status == 404)
        {
            return new NotFoundObjectResult("The .eml blob was not found.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Preview failed for blob {BlobName}", blobName);
            return new ObjectResult(new { error = ex.Message }) { StatusCode = 500 };
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

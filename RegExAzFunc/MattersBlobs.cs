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

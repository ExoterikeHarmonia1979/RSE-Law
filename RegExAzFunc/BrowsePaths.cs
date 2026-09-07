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

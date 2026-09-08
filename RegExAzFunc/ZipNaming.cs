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

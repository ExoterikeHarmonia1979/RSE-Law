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

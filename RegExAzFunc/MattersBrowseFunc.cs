using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using System.IO.Compression;

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
            "probe" => await ProbeAsync(container, prefix),
            "zip" => await ZipAsync(req, container, prefix),
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
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // Broad on purpose: a short zip with a manifest beats a silently short
                    // zip. OperationCanceledException is the exception - the client hung up,
                    // and writing a manifest into a stream nobody is reading is pointless.
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
}

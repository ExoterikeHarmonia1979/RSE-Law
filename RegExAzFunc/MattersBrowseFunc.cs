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

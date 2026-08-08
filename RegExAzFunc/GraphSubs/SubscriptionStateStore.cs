using System.Text;
using System.Text.Json;
using Azure;
using Azure.Data.Tables;
using Azure.Storage.Blobs;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Company.Function.GraphSubs;

public sealed class SubscriptionEntity : ITableEntity
{
    /// <summary>Partner topic name.</summary>
    public string PartitionKey { get; set; } = "";
    /// <summary>Lowercased mail address.</summary>
    public string RowKey { get; set; } = "";
    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string UserEmail { get; set; } = "";
    public string UserObjectId { get; set; } = "";
    public string SubscriptionId { get; set; } = "";
    public string Resource { get; set; } = "";
    public string ChangeType { get; set; } = "";
    public DateTimeOffset? ExpirationDateTime { get; set; }
    public DateTimeOffset? LastRenewedUtc { get; set; }
    /// <summary>When this mailbox's subscription id last changed. Surfaced by
    /// GraphSubStatus so a consumer holding a cached list can detect drift.</summary>
    public DateTimeOffset? SubscriptionIdChangedUtc { get; set; }
    public string Status { get; set; } = "Active";
    public string? LastError { get; set; }
}

/// <summary>
/// System of record for subscription state, plus publisher of the <c>arrUsers</c>
/// projection.
///
/// A hand-edited file cannot be the source of truth for something that mutates every few
/// days, but the legacy Power Automate flow is fed by exactly that shape — so the table is
/// authoritative and the projection is regenerated on every mutating run. Letting them
/// drift is what produced the original 41-mailbox gap.
/// </summary>
public sealed class SubscriptionStateStore
{
    private const string TableName = "GraphSubscriptions";

    private readonly TableClient _table;
    private readonly BlobContainerClient _container;
    private readonly ILogger<SubscriptionStateStore> _log;
    private readonly GraphSubOptions _opt;

    public SubscriptionStateStore(
        IOptions<GraphSubOptions> opt,
        ILogger<SubscriptionStateStore> log,
        IConfiguration config)
    {
        _opt = opt.Value;
        _log = log;

        var conn = config["AzureWebJobsStorage"];
        if (string.IsNullOrWhiteSpace(conn))
            throw new InvalidOperationException("AzureWebJobsStorage is not configured.");

        _table = new TableClient(conn, TableName);
        _container = new BlobContainerClient(conn, _opt.ProjectionContainer);
    }

    private readonly SemaphoreSlim _initGate = new(1, 1);
    private bool _initialised;

    /// <summary>
    /// Creates the table and container if absent. Called automatically by every operation —
    /// the read-only endpoints have no reason to know about provisioning, and relying on a
    /// caller to do it first meant a cold environment returned 500 on the status endpoint.
    /// </summary>
    public async Task InitAsync(CancellationToken ct = default)
    {
        if (_initialised) return;

        await _initGate.WaitAsync(ct);
        try
        {
            if (_initialised) return;
            await _table.CreateIfNotExistsAsync(cancellationToken: ct);
            await _container.CreateIfNotExistsAsync(cancellationToken: ct);
            _initialised = true;
        }
        finally
        {
            _initGate.Release();
        }
    }

    public async Task<List<SubscriptionEntity>> GetAllAsync(CancellationToken ct = default)
    {
        await InitAsync(ct);

        var list = new List<SubscriptionEntity>();
        await foreach (var e in _table.QueryAsync<SubscriptionEntity>(cancellationToken: ct))
            list.Add(e);
        return list;
    }

    public async Task UpsertAsync(SubscriptionEntity entity, CancellationToken ct = default)
    {
        await InitAsync(ct);

        entity.PartitionKey = string.IsNullOrWhiteSpace(entity.PartitionKey) ? "unknown" : entity.PartitionKey;
        entity.RowKey = entity.UserEmail.ToLowerInvariant();
        await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace, ct);
    }

    public async Task RemoveAsync(string partitionKey, string email, CancellationToken ct = default)
    {
        await InitAsync(ct);

        try { await _table.DeleteEntityAsync(partitionKey, email.ToLowerInvariant(), cancellationToken: ct); }
        catch (RequestFailedException ex) when (ex.Status == 404) { /* already gone */ }
    }

    /// <summary>
    /// Rewrites the <c>arrUsers</c> projection from live state. The envelope, property names
    /// and casing are a contract consumed by Power Automate — do not reshape them.
    /// </summary>
    public async Task<string> PublishProjectionAsync(
        IEnumerable<(string Email, string SubscriptionId)> rows, CancellationToken ct = default)
    {
        await InitAsync(ct);

        var ordered = rows
            .Where(r => !string.IsNullOrWhiteSpace(r.SubscriptionId))
            .OrderBy(r => r.Email, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var sb = new StringBuilder();
        sb.AppendLine("{");
        sb.AppendLine("    \"body\": {");
        sb.AppendLine("        \"name\": \"arrUsers\",");
        sb.AppendLine("        \"type\": \"Array\",");
        sb.AppendLine("        \"value\": [");

        for (var i = 0; i < ordered.Count; i++)
        {
            var comma = i < ordered.Count - 1 ? "," : "";
            sb.AppendLine("            {");
            sb.AppendLine($"                \"UserEmail\": \"{ordered[i].Email}\",");
            sb.AppendLine($"                \"subscriptionId\": \"{ordered[i].SubscriptionId}\"");
            sb.AppendLine($"            }}{comma}");
        }

        sb.AppendLine("        ]");
        sb.AppendLine("    }");
        sb.Append('}');

        var json = sb.ToString();

        // Guard the contract: never publish something a strict parser would reject.
        using (var _ = JsonDocument.Parse(json)) { }

        var blob = _container.GetBlobClient(_opt.ProjectionBlob);
        await blob.UploadAsync(BinaryData.FromString(json), overwrite: true, cancellationToken: ct);

        _log.LogInformation("Published arrUsers projection with {Count} entries to {Container}/{Blob}.",
            ordered.Count, _opt.ProjectionContainer, _opt.ProjectionBlob);

        return json;
    }

    public async Task<string?> ReadProjectionAsync(CancellationToken ct = default)
    {
        await InitAsync(ct);

        var blob = _container.GetBlobClient(_opt.ProjectionBlob);
        if (!await blob.ExistsAsync(ct)) return null;

        var res = await blob.DownloadContentAsync(ct);
        return res.Value.Content.ToString();
    }
}

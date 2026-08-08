using System.Text;
using System.Text.Json;
using Company.Function.GraphSubs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Company.Function;

/// <summary>
/// HTTP surface for the Graph mail-subscription automation.
///
///   POST /api/graphsubs/reconcile  -> on-demand reconcile / single-user onboarding
///   GET  /api/graphsubs/status     -> health report (shape may evolve)
///   GET  /api/graphsubs/users      -> the frozen arrUsers envelope (contract — do not reshape)
///   POST /api/graphsubs/lifecycle  -> Event Grid handler for subscriptionReauthorizationRequired
/// </summary>
public class GraphSubEndpoints
{
    private readonly ReconcileEngine _engine;
    private readonly SubscriptionStateStore _store;
    private readonly GraphApiClient _graph;
    private readonly ILogger<GraphSubEndpoints> _logger;

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public GraphSubEndpoints(
        ReconcileEngine engine,
        SubscriptionStateStore store,
        GraphApiClient graph,
        ILogger<GraphSubEndpoints> logger)
    {
        _engine = engine;
        _store = store;
        _graph = graph;
        _logger = logger;
    }

    /// <summary>
    /// Reconcile on demand. Always returns 200 when the run completes, even with per-user
    /// failures — partial failure is normal, and a 5xx would make Power Automate retry the
    /// entire sweep. Non-200 is reserved for bad input and unreachable dependencies.
    /// </summary>
    [Function("GraphSubReconcile")]
    public async Task<IActionResult> ReconcileAsync(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "graphsubs/reconcile")] HttpRequest req,
        CancellationToken ct)
    {
        ReconcileRequest request;
        try
        {
            using var reader = new StreamReader(req.Body);
            var body = await reader.ReadToEndAsync(ct);
            request = string.IsNullOrWhiteSpace(body)
                ? new ReconcileRequest()
                : JsonSerializer.Deserialize<ReconcileRequest>(body, Json) ?? new ReconcileRequest();
        }
        catch (JsonException ex)
        {
            return new BadRequestObjectResult(new { error = "Invalid JSON body", detail = ex.Message });
        }

        try
        {
            var report = await _engine.RunAsync(request, ct);
            return new OkObjectResult(report);
        }
        catch (InvalidOperationException ex)
        {
            // Configuration or credential problems — genuinely the caller's problem to fix.
            _logger.LogError(ex, "GraphSubReconcile could not start.");
            return new ObjectResult(new { error = ex.Message }) { StatusCode = 500 };
        }
    }

    /// <summary>Current state and counts, for Power Automate alerting and eyeballing.</summary>
    [Function("GraphSubStatus")]
    public async Task<IActionResult> StatusAsync(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "graphsubs/status")] HttpRequest req,
        CancellationToken ct)
    {
        var hours = int.TryParse(req.Query["expiringWithinHours"], out var h) ? h : 48;
        var now = DateTimeOffset.UtcNow;
        var cutoff = now.AddHours(hours);

        var live = await _graph.ListSubscriptionsAsync(ct);
        var state = await _store.GetAllAsync(ct);

        var items = live
            .OrderBy(s => s.Mailbox, StringComparer.OrdinalIgnoreCase)
            .Select(s => new
            {
                userEmail = s.Mailbox,
                subscriptionId = s.Id,
                partnerTopic = s.PartnerTopic,
                expirationDateTime = s.ExpirationDateTime,
                status = s.ExpirationDateTime < now ? "Expired"
                       : s.ExpirationDateTime < cutoff ? "ExpiringSoon"
                       : "Active"
            })
            .ToList();

        var lastRun = state.Count == 0 ? (DateTimeOffset?)null : state.Max(e => e.LastRenewedUtc);
        var idChanged = state.Count == 0 ? null : state.Max(e => e.SubscriptionIdChangedUtc);

        return new OkObjectResult(new
        {
            counts = new
            {
                active = items.Count(i => i.status == "Active"),
                expiringSoon = items.Count(i => i.status == "ExpiringSoon"),
                expired = items.Count(i => i.status == "Expired"),
                total = items.Count,
                tracked = state.Count
            },
            nextExpiry = items.Count == 0 ? null : items.Min(i => (DateTimeOffset?)i.expirationDateTime),
            lastRunUtc = lastRun,
            subscriptionIdChangedSince = idChanged,
            items
        });
    }

    /// <summary>
    /// The arrUsers envelope, byte-compatible with the file the legacy flow consumes. This
    /// is a frozen contract: same nesting, same UserEmail / subscriptionId casing. Point the
    /// flow's Initialize-variable action here instead of pasting a literal, and the list
    /// stops going stale.
    /// </summary>
    [Function("GraphSubUsers")]
    public async Task<IActionResult> UsersAsync(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "graphsubs/users")] HttpRequest req,
        CancellationToken ct)
    {
        // Generated from live Graph state rather than the stored projection, so it cannot
        // serve a stale answer if a previous publish failed.
        var live = await _graph.ListSubscriptionsAsync(ct);
        var json = await _store.PublishProjectionAsync(live.Select(s => (s.Mailbox, s.Id)), ct);

        return new ContentResult
        {
            Content = json,
            ContentType = "application/json",
            StatusCode = 200
        };
    }

    /// <summary>
    /// Event Grid handler for <c>microsoft.graph.subscriptionReauthorizationRequired</c>.
    /// Handles the CloudEvents validation handshake, then reauthorizes by renewing.
    ///
    /// Always returns 200, including for events it ignores — a non-200 makes Event Grid
    /// redeliver indefinitely.
    /// </summary>
    [Function("GraphSubLifecycle")]
    public async Task<IActionResult> LifecycleAsync(
        [HttpTrigger(AuthorizationLevel.Function, "options", "post", Route = "graphsubs/lifecycle")] HttpRequest req,
        CancellationToken ct)
    {
        // CloudEvents v1.0 abuse-protection handshake.
        if (HttpMethods.IsOptions(req.Method))
        {
            var origin = req.Headers["WebHook-Request-Origin"].ToString();
            req.HttpContext.Response.Headers["WebHook-Allowed-Origin"] = string.IsNullOrEmpty(origin) ? "*" : origin;
            req.HttpContext.Response.Headers["WebHook-Allowed-Rate"] = "*";
            return new OkResult();
        }

        using var reader = new StreamReader(req.Body, Encoding.UTF8);
        var body = await reader.ReadToEndAsync(ct);
        if (string.IsNullOrWhiteSpace(body)) return new OkResult();

        try
        {
            using var doc = JsonDocument.Parse(body);
            var events = doc.RootElement.ValueKind == JsonValueKind.Array
                ? doc.RootElement.EnumerateArray().ToList()
                : new List<JsonElement> { doc.RootElement };

            var ids = new List<string>();

            foreach (var e in events)
            {
                // Event Grid schema validation event (non-CloudEvents subscriptions).
                if (e.TryGetProperty("eventType", out var et)
                    && et.GetString() == "Microsoft.EventGrid.SubscriptionValidationEvent")
                {
                    var code = e.GetProperty("data").GetProperty("validationCode").GetString();
                    return new OkObjectResult(new { validationResponse = code });
                }

                if (e.TryGetProperty("data", out var data)
                    && data.TryGetProperty("subscriptionId", out var sid)
                    && sid.GetString() is { Length: > 0 } id)
                    ids.Add(id);
            }

            foreach (var id in ids.Distinct())
            {
                var result = await _graph.RenewSubscriptionAsync(
                    id, DateTimeOffset.UtcNow.AddDays(6), ct);

                if (result.Ok)
                    _logger.LogInformation("Reauthorized subscription {Id} via lifecycle event.", id);
                else
                    _logger.LogWarning("Lifecycle reauthorization failed for {Id}: {Reason} {Error}",
                        id, result.Reason, result.Error);
            }
        }
        catch (JsonException ex)
        {
            // Do not 4xx — Event Grid would retry a payload we will never parse.
            _logger.LogWarning(ex, "Unparseable lifecycle payload; acknowledging to stop redelivery.");
        }

        return new OkResult();
    }
}

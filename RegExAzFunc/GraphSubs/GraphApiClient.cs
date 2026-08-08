using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Company.Function.GraphSubs;

/// <summary>Why a per-user operation didn't succeed. Closed set — Power Automate and the
/// nightly email branch on these, so never emit free text.</summary>
public enum FailureReason
{
    None,
    AlreadyActive,
    MailboxNotFound,
    Throttled,
    PermissionDenied,
    /// <summary>The partner topic exists but its subscription is gone. Graph refuses to
    /// recreate under that name until the stale topic is deleted. This is the mechanism
    /// that silently killed 41 mailboxes under the old flow.</summary>
    OrphanedTopic,
    TopicUnavailable,
    GraphError
}

public sealed record GraphUser(string Id, string Upn, string Mail, bool Enabled, string DisplayName);

public sealed class GraphSubscription
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("resource")] public string Resource { get; set; } = "";
    [JsonPropertyName("changeType")] public string ChangeType { get; set; } = "";
    [JsonPropertyName("notificationUrl")] public string NotificationUrl { get; set; } = "";
    [JsonPropertyName("lifecycleNotificationUrl")] public string? LifecycleNotificationUrl { get; set; }
    [JsonPropertyName("expirationDateTime")] public DateTimeOffset ExpirationDateTime { get; set; }
    [JsonPropertyName("applicationId")] public string? ApplicationId { get; set; }

    /// <summary>Mailbox address parsed out of <c>/users/{x}/messages</c>.</summary>
    public string Mailbox =>
        Resource.Replace("/users/", "", StringComparison.OrdinalIgnoreCase)
                .Replace("/messages", "", StringComparison.OrdinalIgnoreCase)
                .Trim('/');

    public string? PartnerTopic
    {
        get
        {
            var m = System.Text.RegularExpressions.Regex.Match(
                NotificationUrl, @"partnertopic=([^&]+)",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            return m.Success ? m.Groups[1].Value : null;
        }
    }
}

public sealed record GraphResult<T>(bool Ok, T? Value, FailureReason Reason, string? Error)
{
    public static GraphResult<T> Success(T v) => new(true, v, FailureReason.None, null);
    public static GraphResult<T> Fail(FailureReason r, string msg) => new(false, default, r, msg);
}

/// <summary>
/// Thin typed client over Microsoft Graph for subscription lifecycle, user enumeration and
/// notification mail.
///
/// Deliberately HttpClient rather than the Microsoft.Graph SDK: this code has to classify
/// specific error payloads (notably <c>StoreBadRequest</c> for orphaned partner topics) and
/// also drive ARM, so precise control over status codes and bodies matters more than the
/// SDK's convenience.
/// </summary>
public sealed class GraphApiClient
{
    private const string Base = "https://graph.microsoft.com/v1.0";

    private readonly HttpClient _http;
    private readonly GraphCredentialProvider _cred;
    private readonly GraphSubOptions _opt;
    private readonly ILogger<GraphApiClient> _log;

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public GraphApiClient(
        HttpClient http,
        GraphCredentialProvider cred,
        IOptions<GraphSubOptions> opt,
        ILogger<GraphApiClient> log)
    {
        _http = http;
        _cred = cred;
        _opt = opt.Value;
        _log = log;
    }

    private async Task<HttpRequestMessage> RequestAsync(HttpMethod m, string url, CancellationToken ct)
    {
        var req = new HttpRequestMessage(m, url);
        req.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer", await _cred.GetGraphTokenAsync(ct));
        return req;
    }

    // ------------------------------------------------------------------ users

    /// <summary>
    /// All enabled member users that have a mail address. Mailbox purpose is checked
    /// separately — <c>mail</c> being set does not prove a mailbox exists.
    /// </summary>
    public async Task<List<GraphUser>> ListActiveUsersAsync(CancellationToken ct = default)
    {
        var users = new List<GraphUser>();
        var url = $"{Base}/users?$select=id,userPrincipalName,mail,accountEnabled,userType,displayName&$top=999";

        while (url is not null)
        {
            using var req = await RequestAsync(HttpMethod.Get, url, ct);
            using var res = await _http.SendAsync(req, ct);
            res.EnsureSuccessStatusCode();

            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            foreach (var u in doc.RootElement.GetProperty("value").EnumerateArray())
            {
                var enabled = u.TryGetProperty("accountEnabled", out var e) && e.ValueKind == JsonValueKind.True;
                var mail = u.TryGetProperty("mail", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() : null;
                var type = u.TryGetProperty("userType", out var t) ? t.GetString() : null;

                if (!enabled || string.IsNullOrWhiteSpace(mail)) continue;
                if (!string.Equals(type, "Member", StringComparison.OrdinalIgnoreCase)) continue;

                users.Add(new GraphUser(
                    u.GetProperty("id").GetString()!,
                    u.TryGetProperty("userPrincipalName", out var p) ? p.GetString() ?? "" : "",
                    mail!,
                    true,
                    u.TryGetProperty("displayName", out var d) ? d.GetString() ?? "" : ""));
            }

            url = doc.RootElement.TryGetProperty("@odata.nextLink", out var n) ? n.GetString() : null;
        }

        return users;
    }

    /// <summary>
    /// Mailbox purpose (<c>user</c>, <c>shared</c>, <c>room</c>, <c>equipment</c>…), or null
    /// when no mailbox is provisioned. A 404 here is the reliable "this account has no
    /// mailbox" signal — 27 enabled accounts in this tenant are in that state.
    /// </summary>
    public async Task<string?> GetMailboxPurposeAsync(string userId, CancellationToken ct = default)
    {
        using var req = await RequestAsync(HttpMethod.Get, $"{Base}/users/{userId}/mailboxSettings?$select=userPurpose", ct);
        using var res = await _http.SendAsync(req, ct);

        if (res.StatusCode is HttpStatusCode.NotFound) return null;
        if (!res.IsSuccessStatusCode) return null;

        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        return doc.RootElement.TryGetProperty("userPurpose", out var p) ? p.GetString() : null;
    }

    public async Task<HashSet<string>> GetGroupMemberUpnsAsync(string groupId, CancellationToken ct = default)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var url = $"{Base}/groups/{groupId}/members?$select=userPrincipalName,mail&$top=999";

        while (url is not null)
        {
            using var req = await RequestAsync(HttpMethod.Get, url, ct);
            using var res = await _http.SendAsync(req, ct);
            if (!res.IsSuccessStatusCode)
            {
                _log.LogWarning("Exclusion group {Group} could not be read ({Status}); no exclusions applied.",
                    groupId, (int)res.StatusCode);
                return set;
            }

            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            foreach (var m in doc.RootElement.GetProperty("value").EnumerateArray())
            {
                if (m.TryGetProperty("mail", out var e) && e.ValueKind == JsonValueKind.String)
                    set.Add(e.GetString()!);
                if (m.TryGetProperty("userPrincipalName", out var u) && u.ValueKind == JsonValueKind.String)
                    set.Add(u.GetString()!);
            }

            url = doc.RootElement.TryGetProperty("@odata.nextLink", out var n) ? n.GetString() : null;
        }

        return set;
    }

    // ---------------------------------------------------------- subscriptions

    /// <summary>
    /// Every subscription owned by the configured app. Graph scopes this to the calling
    /// appId, so an unexpectedly empty result means the wrong identity, not an outage.
    /// </summary>
    public async Task<List<GraphSubscription>> ListSubscriptionsAsync(CancellationToken ct = default)
    {
        var all = new List<GraphSubscription>();
        var url = $"{Base}/subscriptions";

        while (url is not null)
        {
            using var req = await RequestAsync(HttpMethod.Get, url, ct);
            using var res = await _http.SendAsync(req, ct);
            res.EnsureSuccessStatusCode();

            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            foreach (var s in doc.RootElement.GetProperty("value").EnumerateArray())
            {
                var parsed = s.Deserialize<GraphSubscription>(Json);
                if (parsed is not null) all.Add(parsed);
            }

            url = doc.RootElement.TryGetProperty("@odata.nextLink", out var n) ? n.GetString() : null;
        }

        return all;
    }

    public async Task<GraphResult<GraphSubscription>> CreateSubscriptionAsync(
        string mailbox, DateTimeOffset expiration, CancellationToken ct = default)
    {
        var url = _opt.NotificationUrlFor(mailbox);
        var payload = new
        {
            changeType = "Created,Updated",
            notificationUrl = url,
            lifecycleNotificationUrl = url,
            resource = $"/users/{mailbox}/messages",
            expirationDateTime = expiration.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.0000000Z"),
            clientState = _opt.ClientState
        };

        return await SendWithRetryAsync<GraphSubscription>(
            HttpMethod.Post, $"{Base}/subscriptions", payload, ct);
    }

    public async Task<GraphResult<GraphSubscription>> RenewSubscriptionAsync(
        string subscriptionId, DateTimeOffset expiration, CancellationToken ct = default)
    {
        var payload = new
        {
            expirationDateTime = expiration.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.0000000Z")
        };

        return await SendWithRetryAsync<GraphSubscription>(
            HttpMethod.Patch, $"{Base}/subscriptions/{subscriptionId}", payload, ct);
    }

    public async Task<GraphResult<bool>> DeleteSubscriptionAsync(
        string subscriptionId, CancellationToken ct = default)
    {
        var r = await SendWithRetryAsync<object>(
            HttpMethod.Delete, $"{Base}/subscriptions/{subscriptionId}", null, ct);

        // Already gone is the desired end state, not a failure.
        if (!r.Ok && r.Reason == FailureReason.MailboxNotFound)
            return GraphResult<bool>.Success(true);

        return r.Ok
            ? GraphResult<bool>.Success(true)
            : GraphResult<bool>.Fail(r.Reason, r.Error!);
    }

    // ------------------------------------------------------------------- mail

    public async Task SendMailAsync(string subject, string htmlBody, CancellationToken ct = default)
    {
        var recipients = _opt.NotifyRecipients();
        if (recipients.Length == 0 || string.IsNullOrWhiteSpace(_opt.NotifyFrom))
        {
            _log.LogWarning("Notification skipped: GraphSub__NotifyTo/NotifyFrom not configured.");
            return;
        }

        var payload = new
        {
            message = new
            {
                subject,
                body = new { contentType = "HTML", content = htmlBody },
                toRecipients = recipients.Select(r => new { emailAddress = new { address = r } }).ToArray()
            },
            saveToSentItems = false
        };

        // Sent with the notifier app's token, not the archive app's — see
        // GraphCredentialProvider.GetNotifyTokenAsync for why they must stay separate.
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{Base}/users/{_opt.NotifyFrom}/sendMail");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _cred.GetNotifyTokenAsync(ct));
        req.Content = new StringContent(JsonSerializer.Serialize(payload, Json), Encoding.UTF8, "application/json");

        using var res = await _http.SendAsync(req, ct);
        if (!res.IsSuccessStatusCode)
        {
            var body = await res.Content.ReadAsStringAsync(ct);
            // Never let a notification failure mask the run's real outcome.
            _log.LogError("Notification email failed ({Status}): {Body}", (int)res.StatusCode, body);
        }
    }

    // --------------------------------------------------------------- plumbing

    private async Task<GraphResult<T>> SendWithRetryAsync<T>(
        HttpMethod method, string url, object? payload, CancellationToken ct)
    {
        const int maxAttempts = 4;

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            using var req = await RequestAsync(method, url, ct);
            if (payload is not null)
                req.Content = new StringContent(
                    JsonSerializer.Serialize(payload, Json), Encoding.UTF8, "application/json");

            using var res = await _http.SendAsync(req, ct);
            var body = await res.Content.ReadAsStringAsync(ct);

            if (res.IsSuccessStatusCode)
            {
                if (typeof(T) == typeof(object) || string.IsNullOrWhiteSpace(body))
                    return GraphResult<T>.Success(default!);

                return GraphResult<T>.Success(JsonSerializer.Deserialize<T>(body, Json)!);
            }

            if ((res.StatusCode is HttpStatusCode.TooManyRequests or HttpStatusCode.ServiceUnavailable)
                && attempt < maxAttempts)
            {
                var delay = res.Headers.RetryAfter?.Delta
                            ?? TimeSpan.FromSeconds(Math.Pow(2, attempt));
                _log.LogWarning("Graph throttled ({Status}); retrying in {Delay}s (attempt {A}/{Max}).",
                    (int)res.StatusCode, delay.TotalSeconds, attempt, maxAttempts);
                await Task.Delay(delay, ct);
                continue;
            }

            return GraphResult<T>.Fail(Classify(res.StatusCode, body), $"HTTP {(int)res.StatusCode}: {Describe(body)}");
        }

        return GraphResult<T>.Fail(FailureReason.Throttled, "Retries exhausted while throttled.");
    }

    /// <summary>
    /// Maps a Graph error onto the closed reason set. The <c>StoreBadRequest</c> case is the
    /// important one: it means a partner topic with that name already exists without a live
    /// subscription, and no amount of retrying will fix it.
    /// </summary>
    private static FailureReason Classify(HttpStatusCode status, string body)
    {
        var code = ErrorCode(body);
        var message = ErrorMessage(body) ?? "";

        if (string.Equals(code, "StoreBadRequest", StringComparison.OrdinalIgnoreCase)
            && message.Contains("already present", StringComparison.OrdinalIgnoreCase))
            return FailureReason.OrphanedTopic;

        return status switch
        {
            HttpStatusCode.NotFound => FailureReason.MailboxNotFound,
            HttpStatusCode.Forbidden => FailureReason.PermissionDenied,
            HttpStatusCode.Unauthorized => FailureReason.PermissionDenied,
            HttpStatusCode.TooManyRequests => FailureReason.Throttled,
            HttpStatusCode.BadRequest when message.Contains("mailbox", StringComparison.OrdinalIgnoreCase)
                => FailureReason.MailboxNotFound,
            HttpStatusCode.BadRequest when message.Contains("partner topic", StringComparison.OrdinalIgnoreCase)
                => FailureReason.TopicUnavailable,
            _ => FailureReason.GraphError
        };
    }

    private static string? ErrorCode(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.TryGetProperty("error", out var e)
                && e.TryGetProperty("code", out var c) ? c.GetString() : null;
        }
        catch { return null; }
    }

    private static string? ErrorMessage(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.TryGetProperty("error", out var e)
                && e.TryGetProperty("message", out var m) ? m.GetString() : null;
        }
        catch { return null; }
    }

    private static string Describe(string body) => ErrorMessage(body) ?? Truncate(body, 400);

    private static string Truncate(string s, int n) =>
        string.IsNullOrEmpty(s) ? "" : (s.Length <= n ? s : s[..n] + "…");
}

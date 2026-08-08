using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Company.Function.GraphSubs;

public sealed record PartnerTopicState(bool Exists, string? ActivationState, string? ProvisioningState)
{
    public bool IsActivated =>
        string.Equals(ActivationState, "Activated", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// ARM operations for Event Grid partner topics.
///
/// Graph mints the partner topic implicitly when a subscription is created, but it lands
/// <c>NeverActivated</c> and self-destructs after 7 days. Until it is activated AND has an
/// event subscription pointing at the Service Bus queue, the Graph subscription looks
/// perfectly healthy and delivers nothing — so every create path must finish the job here.
/// </summary>
public sealed class EventGridArmClient
{
    private const string ApiVersion = "2022-06-15";
    private const string Arm = "https://management.azure.com";

    private readonly HttpClient _http;
    private readonly GraphCredentialProvider _cred;
    private readonly GraphSubOptions _opt;
    private readonly ILogger<EventGridArmClient> _log;

    public EventGridArmClient(
        HttpClient http,
        GraphCredentialProvider cred,
        IOptions<GraphSubOptions> opt,
        ILogger<EventGridArmClient> log)
    {
        _http = http;
        _cred = cred;
        _opt = opt.Value;
        _log = log;
    }

    private string TopicUrl(string topic) =>
        $"{Arm}/subscriptions/{_opt.AzureSubscriptionId}/resourceGroups/{_opt.ResourceGroup}" +
        $"/providers/Microsoft.EventGrid/partnerTopics/{topic}";

    private async Task<HttpRequestMessage> RequestAsync(HttpMethod m, string url, CancellationToken ct)
    {
        var req = new HttpRequestMessage(m, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _cred.GetArmTokenAsync(ct));
        return req;
    }

    public async Task<PartnerTopicState> GetTopicAsync(string topic, CancellationToken ct = default)
    {
        using var req = await RequestAsync(HttpMethod.Get, $"{TopicUrl(topic)}?api-version={ApiVersion}", ct);
        using var res = await _http.SendAsync(req, ct);

        if (res.StatusCode == HttpStatusCode.NotFound)
            return new PartnerTopicState(false, null, null);

        res.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        var p = doc.RootElement.GetProperty("properties");

        return new PartnerTopicState(
            true,
            p.TryGetProperty("activationState", out var a) ? a.GetString() : null,
            p.TryGetProperty("provisioningState", out var s) ? s.GetString() : null);
    }

    /// <summary>
    /// Waits for Graph to materialise the topic, activates it, and verifies. Returns the
    /// final state rather than trusting the activate call's response — "created but never
    /// activated" is a false green that must not be reported as success.
    /// </summary>
    public async Task<PartnerTopicState> EnsureActivatedAsync(
        string topic, CancellationToken ct = default, int waitSeconds = 60)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(waitSeconds);
        PartnerTopicState state;

        while (true)
        {
            state = await GetTopicAsync(topic, ct);
            if (state.Exists) break;
            if (DateTimeOffset.UtcNow > deadline)
                return state;
            await Task.Delay(TimeSpan.FromSeconds(3), ct);
        }

        if (state.IsActivated) return state;

        using (var req = await RequestAsync(HttpMethod.Post, $"{TopicUrl(topic)}/activate?api-version={ApiVersion}", ct))
        using (var res = await _http.SendAsync(req, ct))
        {
            if (!res.IsSuccessStatusCode)
            {
                var body = await res.Content.ReadAsStringAsync(ct);
                _log.LogError("Activating partner topic {Topic} failed ({Status}): {Body}",
                    topic, (int)res.StatusCode, body);
                return await GetTopicAsync(topic, ct);
            }
        }

        return await GetTopicAsync(topic, ct);
    }

    /// <summary>
    /// Creates the event subscription routing a topic to <c>speventgridqueue</c>, matching the
    /// configuration of the existing 72 (CloudEvents v1.0, no filter, 30 attempts / 1440 min),
    /// plus dead-lettering when a container is configured. Idempotent.
    /// </summary>
    public async Task<bool> EnsureEventSubscriptionAsync(string topic, CancellationToken ct = default)
    {
        var name = $"Sub-{topic}";
        var url = $"{TopicUrl(topic)}/eventSubscriptions/{name}?api-version={ApiVersion}";

        using (var get = await RequestAsync(HttpMethod.Get, url, ct))
        using (var existing = await _http.SendAsync(get, ct))
        {
            if (existing.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(await existing.Content.ReadAsStringAsync(ct));
                var st = doc.RootElement.GetProperty("properties").TryGetProperty("provisioningState", out var p)
                    ? p.GetString() : null;
                if (string.Equals(st, "Succeeded", StringComparison.OrdinalIgnoreCase)) return true;
            }
        }

        object properties = _opt.DeadLetterContainerResourceId is { Length: > 0 } dl
            ? new
            {
                destination = Destination(),
                eventDeliverySchema = "CloudEventSchemaV1_0",
                retryPolicy = new { maxDeliveryAttempts = 30, eventTimeToLiveInMinutes = 1440 },
                deadLetterDestination = new
                {
                    endpointType = "StorageBlob",
                    properties = new { resourceId = dl, blobContainerName = "eventgrid-deadletter" }
                }
            }
            : new
            {
                destination = Destination(),
                eventDeliverySchema = "CloudEventSchemaV1_0",
                retryPolicy = new { maxDeliveryAttempts = 30, eventTimeToLiveInMinutes = 1440 }
            };

        var payload = JsonSerializer.Serialize(new { properties });

        using (var put = await RequestAsync(HttpMethod.Put, url, ct))
        {
            put.Content = new StringContent(payload, Encoding.UTF8, "application/json");
            using var res = await _http.SendAsync(put, ct);
            if (!res.IsSuccessStatusCode)
            {
                _log.LogError("Creating event subscription {Name} failed ({Status}): {Body}",
                    name, (int)res.StatusCode, await res.Content.ReadAsStringAsync(ct));
                return false;
            }
        }

        // Provisioning is asynchronous — it returns "Creating" and settles seconds later.
        var deadline = DateTimeOffset.UtcNow.AddSeconds(90);
        while (DateTimeOffset.UtcNow < deadline)
        {
            using var poll = await RequestAsync(HttpMethod.Get, url, ct);
            using var res = await _http.SendAsync(poll, ct);
            if (res.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
                var st = doc.RootElement.GetProperty("properties").TryGetProperty("provisioningState", out var p)
                    ? p.GetString() : null;

                if (string.Equals(st, "Succeeded", StringComparison.OrdinalIgnoreCase)) return true;
                if (string.Equals(st, "Failed", StringComparison.OrdinalIgnoreCase)) return false;
            }
            await Task.Delay(TimeSpan.FromSeconds(3), ct);
        }

        _log.LogWarning("Event subscription {Name} did not reach Succeeded within the wait window.", name);
        return false;
    }

    private object Destination() => new
    {
        endpointType = "ServiceBusQueue",
        properties = new { resourceId = _opt.ServiceBusQueueResourceId }
    };

    /// <summary>
    /// Deletes a partner topic. Required whenever a subscription is deleted — a topic left
    /// behind is orphaned, and Graph then refuses to recreate any subscription under that
    /// name, permanently. Leaving orphans is how the previous system lost 41 mailboxes.
    /// </summary>
    public async Task<bool> DeleteTopicAsync(string topic, CancellationToken ct = default)
    {
        using var req = await RequestAsync(HttpMethod.Delete, $"{TopicUrl(topic)}?api-version={ApiVersion}", ct);
        using var res = await _http.SendAsync(req, ct);

        if (res.IsSuccessStatusCode || res.StatusCode == HttpStatusCode.NotFound) return true;

        _log.LogError("Deleting partner topic {Topic} failed ({Status}): {Body}",
            topic, (int)res.StatusCode, await res.Content.ReadAsStringAsync(ct));
        return false;
    }

    public async Task<List<string>> ListTopicsAsync(CancellationToken ct = default)
    {
        var names = new List<string>();
        var url = $"{Arm}/subscriptions/{_opt.AzureSubscriptionId}/resourceGroups/{_opt.ResourceGroup}" +
                  $"/providers/Microsoft.EventGrid/partnerTopics?api-version={ApiVersion}";

        while (url is not null)
        {
            using var req = await RequestAsync(HttpMethod.Get, url, ct);
            using var res = await _http.SendAsync(req, ct);
            res.EnsureSuccessStatusCode();

            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            foreach (var t in doc.RootElement.GetProperty("value").EnumerateArray())
                names.Add(t.GetProperty("name").GetString()!);

            // ARM percent-encodes $skiptoken in nextLink; follow it verbatim.
            url = doc.RootElement.TryGetProperty("nextLink", out var n) ? n.GetString() : null;
        }

        return names;
    }
}

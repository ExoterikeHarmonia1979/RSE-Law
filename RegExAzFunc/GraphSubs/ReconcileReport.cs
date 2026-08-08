using System.Text.Json.Serialization;

namespace Company.Function.GraphSubs;

public sealed class UserOutcome
{
    [JsonPropertyName("userEmail")] public string UserEmail { get; set; } = "";
    [JsonPropertyName("subscriptionId")] public string? SubscriptionId { get; set; }
    [JsonPropertyName("partnerTopic")] public string? PartnerTopic { get; set; }
    [JsonPropertyName("expirationDateTime")] public DateTimeOffset? ExpirationDateTime { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }
}

public sealed class ReconcileTotals
{
    [JsonPropertyName("roster")] public int Roster { get; set; }
    [JsonPropertyName("activeBefore")] public int ActiveBefore { get; set; }
    [JsonPropertyName("activeAfter")] public int ActiveAfter { get; set; }
    [JsonPropertyName("created")] public int Created { get; set; }
    [JsonPropertyName("renewed")] public int Renewed { get; set; }
    [JsonPropertyName("repaired")] public int Repaired { get; set; }
    [JsonPropertyName("skipped")] public int Skipped { get; set; }
    [JsonPropertyName("failed")] public int Failed { get; set; }
    [JsonPropertyName("orphans")] public int Orphans { get; set; }
    [JsonPropertyName("noMailbox")] public int NoMailbox { get; set; }
    [JsonPropertyName("excluded")] public int Excluded { get; set; }
}

/// <summary>
/// Result of a reconcile/renew run. Returned as HTTP 200 even when individual mailboxes
/// fail — partial failure is the normal case, and a 5xx would make Power Automate retry
/// the whole sweep. Non-200 is reserved for auth failure, bad input, or an unreachable
/// roster source.
/// </summary>
public sealed class ReconcileReport
{
    [JsonPropertyName("runId")] public string RunId { get; set; } =
        DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + "-" + Guid.NewGuid().ToString("N")[..4];

    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("rosterSource")] public string RosterSource { get; set; } = "";
    [JsonPropertyName("topicNaming")] public string TopicNaming { get; set; } = "";
    [JsonPropertyName("clientId")] public string ClientId { get; set; } = "";
    [JsonPropertyName("startedUtc")] public DateTimeOffset StartedUtc { get; set; } = DateTimeOffset.UtcNow;
    [JsonPropertyName("finishedUtc")] public DateTimeOffset? FinishedUtc { get; set; }
    [JsonPropertyName("durationSeconds")] public double DurationSeconds =>
        ((FinishedUtc ?? DateTimeOffset.UtcNow) - StartedUtc).TotalSeconds;

    [JsonPropertyName("totals")] public ReconcileTotals Totals { get; set; } = new();

    [JsonPropertyName("created")] public List<UserOutcome> Created { get; set; } = new();
    [JsonPropertyName("renewed")] public List<UserOutcome> Renewed { get; set; } = new();
    [JsonPropertyName("repaired")] public List<UserOutcome> Repaired { get; set; } = new();
    [JsonPropertyName("failed")] public List<UserOutcome> Failed { get; set; } = new();
    [JsonPropertyName("orphans")] public List<UserOutcome> Orphans { get; set; } = new();
    [JsonPropertyName("noMailbox")] public List<UserOutcome> NoMailbox { get; set; } = new();

    [JsonPropertyName("arrUsersPublished")] public bool ArrUsersPublished { get; set; }

    /// <summary>Days until the client secret expires. Null means it could not be read,
    /// which is itself a warning — never treat it as "plenty of time".</summary>
    [JsonPropertyName("secretDaysRemaining")] public double? SecretDaysRemaining { get; set; }
    [JsonPropertyName("secretExpiryUnknown")] public bool SecretExpiryUnknown { get; set; }

    [JsonPropertyName("fatalError")] public string? FatalError { get; set; }

    public bool HasProblems =>
        FatalError is not null || Totals.Failed > 0 || SecretWarning || SecretExpiryUnknown;

    public bool SecretWarning => SecretDaysRemaining is { } d && d <= 7;

    public string Outcome =>
        FatalError is not null ? "FAILED"
        : Totals.Failed > 0 ? "COMPLETED WITH ERRORS"
        : "OK";
}

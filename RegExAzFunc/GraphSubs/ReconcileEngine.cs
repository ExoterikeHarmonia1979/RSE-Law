using System.Collections.Concurrent;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Company.Function.GraphSubs;

public sealed class ReconcileRequest
{
    /// <summary>Explicit mailboxes — the onboarding path. Wins over every other source.</summary>
    public string[]? Roster { get; set; }
    public bool DryRun { get; set; } = true;
    /// <summary>Delete subscriptions for mailboxes no longer active. Off by default; when on,
    /// the partner topic is deleted too, or the mailbox becomes unrecoverable by name.</summary>
    public bool DeleteOrphans { get; set; }
    /// <summary>Skip renewal and only create/repair. Used by the onboarding path.</summary>
    public bool SkipRenew { get; set; }
}

/// <summary>
/// The engine behind every entry point: work out who should have a mail subscription, make
/// it so, and renew what already exists.
///
/// Two rules drive most of the design:
///   * a partner topic left behind by a deleted subscription is poison — Graph refuses to
///     recreate under that name, silently and permanently;
///   * a subscription whose topic is unactivated or unwired looks healthy and delivers
///     nothing, so "created" is only reported once delivery is actually possible.
/// </summary>
public sealed class ReconcileEngine
{
    private readonly GraphApiClient _graph;
    private readonly EventGridArmClient _arm;
    private readonly SubscriptionStateStore _store;
    private readonly GraphCredentialProvider _cred;
    private readonly GraphSubOptions _opt;
    private readonly ILogger<ReconcileEngine> _log;

    public ReconcileEngine(
        GraphApiClient graph,
        EventGridArmClient arm,
        SubscriptionStateStore store,
        GraphCredentialProvider cred,
        IOptions<GraphSubOptions> opt,
        ILogger<ReconcileEngine> log)
    {
        _graph = graph;
        _arm = arm;
        _store = store;
        _cred = cred;
        _opt = opt.Value;
        _log = log;
    }

    public async Task<ReconcileReport> RunAsync(ReconcileRequest request, CancellationToken ct = default)
    {
        _opt.Validate();

        var report = new ReconcileReport
        {
            DryRun = request.DryRun,
            TopicNaming = _opt.TopicNaming,
            ClientId = _opt.ClientId
        };

        await _store.InitAsync(ct);

        // Touch the credential early so expiry is known even if the run fails later.
        await _cred.GetGraphTokenAsync(ct);
        report.SecretDaysRemaining = _cred.SecretDaysRemaining(DateTimeOffset.UtcNow);
        report.SecretExpiryUnknown = _cred.SecretExpiryUnknown;

        var live = await _graph.ListSubscriptionsAsync(ct);
        report.Totals.ActiveBefore = live.Count;

        if (live.Count == 0)
            _log.LogWarning(
                "Graph returned 0 subscriptions for app {ClientId}. Subscriptions are scoped to " +
                "their creating app — this is far more likely to be the wrong identity than a " +
                "genuine outage. No mailbox will be created on this basis.",
                _opt.ClientId);

        var byMailbox = live
            .GroupBy(s => s.Mailbox, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

        var (targets, source) = await ResolveRosterAsync(request, report, ct);
        report.RosterSource = source;
        report.Totals.Roster = targets.Count;

        // Refuse to act on an empty roster with live subscriptions present — that
        // combination means enumeration broke, and DeleteOrphans would wipe everything.
        if (targets.Count == 0 && live.Count > 0)
        {
            report.FatalError = "Roster resolved to zero mailboxes while live subscriptions exist; " +
                                "aborting rather than risk deleting active coverage.";
            report.FinishedUtc = DateTimeOffset.UtcNow;
            return report;
        }

        var expiry = DateTimeOffset.UtcNow.AddDays(_opt.RenewToDays);
        var renewCutoff = DateTimeOffset.UtcNow.AddHours(_opt.RenewLeadHours);

        var created = new ConcurrentBag<UserOutcome>();
        var renewed = new ConcurrentBag<UserOutcome>();
        var repaired = new ConcurrentBag<UserOutcome>();
        var failed = new ConcurrentBag<UserOutcome>();

        var options = new ParallelOptions
        {
            MaxDegreeOfParallelism = Math.Max(1, _opt.MaxConcurrency),
            CancellationToken = ct
        };

        await Parallel.ForEachAsync(targets, options, async (target, token) =>
        {
            try
            {
                if (byMailbox.TryGetValue(target.Mail, out var existing))
                {
                    if (request.SkipRenew || existing.ExpirationDateTime > renewCutoff)
                    {
                        Interlocked.Increment(ref _skipped);
                        return;
                    }

                    var outcome = await RenewAsync(existing, target, expiry, request.DryRun, token);
                    if (outcome.Reason is null) renewed.Add(outcome);
                    else if (outcome.Reason == nameof(FailureReason.MailboxNotFound))
                    {
                        // Renewal 404 means the subscription is gone, not the mailbox.
                        // Recreate rather than swallow — swallowing is what lost 41 mailboxes.
                        var re = await CreateAsync(target, expiry, request.DryRun, token);
                        if (re.Reason is null) repaired.Add(re); else failed.Add(re);
                    }
                    else failed.Add(outcome);
                }
                else
                {
                    var outcome = await CreateAsync(target, expiry, request.DryRun, token);
                    if (outcome.Reason is null) created.Add(outcome); else failed.Add(outcome);
                }
            }
            catch (Exception ex)
            {
                failed.Add(new UserOutcome
                {
                    UserEmail = target.Mail,
                    Reason = nameof(FailureReason.GraphError),
                    Message = ex.Message
                });
            }
        });

        report.Created.AddRange(created.OrderBy(o => o.UserEmail, StringComparer.OrdinalIgnoreCase));
        report.Renewed.AddRange(renewed.OrderBy(o => o.UserEmail, StringComparer.OrdinalIgnoreCase));
        report.Repaired.AddRange(repaired.OrderBy(o => o.UserEmail, StringComparer.OrdinalIgnoreCase));
        report.Failed.AddRange(failed.OrderBy(o => o.UserEmail, StringComparer.OrdinalIgnoreCase));

        report.Totals.Created = report.Created.Count;
        report.Totals.Renewed = report.Renewed.Count;
        report.Totals.Repaired = report.Repaired.Count;
        report.Totals.Failed = report.Failed.Count;
        report.Totals.Skipped = _skipped;

        // Orphans: live subscriptions for mailboxes no longer in the roster.
        var rosterSet = targets.Select(t => t.Mail).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var s in live.Where(s => !rosterSet.Contains(s.Mailbox)))
        {
            var o = new UserOutcome
            {
                UserEmail = s.Mailbox,
                SubscriptionId = s.Id,
                PartnerTopic = s.PartnerTopic,
                ExpirationDateTime = s.ExpirationDateTime,
                Reason = "NotInRoster"
            };

            if (request.DeleteOrphans && !request.DryRun)
                o.Message = await DeleteWithTopicAsync(s, ct);

            report.Orphans.Add(o);
        }
        report.Totals.Orphans = report.Orphans.Count;

        var after = await _graph.ListSubscriptionsAsync(ct);
        report.Totals.ActiveAfter = after.Count;

        if (!request.DryRun)
        {
            await _store.PublishProjectionAsync(
                after.Select(s => (s.Mailbox, s.Id)), ct);
            report.ArrUsersPublished = true;
        }

        report.FinishedUtc = DateTimeOffset.UtcNow;
        return report;
    }

    private int _skipped;

    // ------------------------------------------------------------- operations

    private async Task<UserOutcome> CreateAsync(
        RosterTarget target, DateTimeOffset expiry, bool dryRun, CancellationToken ct)
    {
        var topic = _opt.TopicNameFor(target.Mail);
        var outcome = new UserOutcome { UserEmail = target.Mail, PartnerTopic = topic };

        if (dryRun)
        {
            outcome.Message = "would create";
            return outcome;
        }

        var result = await _graph.CreateSubscriptionAsync(target.Mail, expiry, ct);

        if (!result.Ok)
        {
            // A stale topic blocks creation forever under that name. Clear it and retry
            // once; if the topic is shared and in use this will not trigger, because a
            // live topic accepts additional subscriptions.
            if (result.Reason == FailureReason.OrphanedTopic)
            {
                _log.LogWarning("Partner topic {Topic} is orphaned; deleting and retrying {Mail}.",
                    topic, target.Mail);

                if (await _arm.DeleteTopicAsync(topic, ct))
                    result = await _graph.CreateSubscriptionAsync(target.Mail, expiry, ct);
            }

            if (!result.Ok)
            {
                outcome.Reason = result.Reason.ToString();
                outcome.Message = result.Error;
                return outcome;
            }
        }

        var sub = result.Value!;
        outcome.SubscriptionId = sub.Id;
        outcome.ExpirationDateTime = sub.ExpirationDateTime;

        if (!await EnsureDeliveryAsync(topic, outcome, ct)) return outcome;

        await SaveAsync(target, sub, topic, idChanged: true, ct);
        return outcome;
    }

    private async Task<UserOutcome> RenewAsync(
        GraphSubscription existing, RosterTarget target, DateTimeOffset expiry, bool dryRun, CancellationToken ct)
    {
        var outcome = new UserOutcome
        {
            UserEmail = target.Mail,
            SubscriptionId = existing.Id,
            PartnerTopic = existing.PartnerTopic
        };

        if (dryRun)
        {
            outcome.Message = "would renew";
            outcome.ExpirationDateTime = existing.ExpirationDateTime;
            return outcome;
        }

        var result = await _graph.RenewSubscriptionAsync(existing.Id, expiry, ct);
        if (!result.Ok)
        {
            outcome.Reason = result.Reason.ToString();
            outcome.Message = result.Error;
            return outcome;
        }

        outcome.ExpirationDateTime = result.Value!.ExpirationDateTime;
        await SaveAsync(target, result.Value, existing.PartnerTopic ?? "unknown", idChanged: false, ct);
        return outcome;
    }

    /// <summary>
    /// A subscription only counts as created once its topic is activated and routed. Without
    /// this the run reports a false green while the mailbox delivers nowhere.
    /// </summary>
    private async Task<bool> EnsureDeliveryAsync(string topic, UserOutcome outcome, CancellationToken ct)
    {
        var state = await _arm.EnsureActivatedAsync(topic, ct);
        if (!state.IsActivated)
        {
            outcome.Reason = nameof(FailureReason.TopicUnavailable);
            outcome.Message = $"Partner topic {topic} is '{state.ActivationState ?? "missing"}' after activation; " +
                              "events will not be delivered.";
            return false;
        }

        if (!await _arm.EnsureEventSubscriptionAsync(topic, ct))
        {
            outcome.Reason = nameof(FailureReason.TopicUnavailable);
            outcome.Message = $"Partner topic {topic} has no working event subscription to the queue.";
            return false;
        }

        return true;
    }

    private async Task<string> DeleteWithTopicAsync(GraphSubscription sub, CancellationToken ct)
    {
        var del = await _graph.DeleteSubscriptionAsync(sub.Id, ct);
        if (!del.Ok) return $"delete failed: {del.Error}";

        // Per-user topics must go with their subscription or they become orphans. The shared
        // topic is kept — other mailboxes are still using it.
        var topic = sub.PartnerTopic;
        if (topic is not null && !topic.Equals(_opt.PartnerTopic, StringComparison.OrdinalIgnoreCase))
        {
            if (!await _arm.DeleteTopicAsync(topic, ct))
                return "subscription deleted, but its partner topic could not be removed " +
                       "(it is now orphaned and will block recreation under that name)";
        }

        await _store.RemoveAsync(topic ?? "unknown", sub.Mailbox, ct);
        return "deleted";
    }

    private async Task SaveAsync(
        RosterTarget target, GraphSubscription sub, string topic, bool idChanged, CancellationToken ct)
    {
        await _store.UpsertAsync(new SubscriptionEntity
        {
            PartitionKey = topic,
            RowKey = target.Mail.ToLowerInvariant(),
            UserEmail = target.Mail,
            UserObjectId = target.ObjectId,
            SubscriptionId = sub.Id,
            Resource = sub.Resource,
            ChangeType = sub.ChangeType,
            ExpirationDateTime = sub.ExpirationDateTime,
            LastRenewedUtc = DateTimeOffset.UtcNow,
            SubscriptionIdChangedUtc = idChanged ? DateTimeOffset.UtcNow : null,
            Status = "Active",
            LastError = null
        }, ct);
    }

    // ----------------------------------------------------------------- roster

    public sealed record RosterTarget(string Mail, string ObjectId, string DisplayName);

    private async Task<(List<RosterTarget> Targets, string Source)> ResolveRosterAsync(
        ReconcileRequest request, ReconcileReport report, CancellationToken ct)
    {
        if (request.Roster is { Length: > 0 })
        {
            var explicitTargets = request.Roster
                .Select(m => new RosterTarget(m.Trim(), "", ""))
                .ToList();
            return (explicitTargets, "Request");
        }

        var users = await _graph.ListActiveUsersAsync(ct);

        var excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(_opt.ExcludeGroupId))
            excluded = await _graph.GetGroupMemberUpnsAsync(_opt.ExcludeGroupId!, ct);

        Regex? excludePattern = string.IsNullOrWhiteSpace(_opt.ExcludeUpnPattern)
            ? null
            : new Regex(_opt.ExcludeUpnPattern!, RegexOptions.IgnoreCase);

        var purposes = _opt.IncludedPurposes();
        var keep = new ConcurrentBag<RosterTarget>();
        var noMailbox = new ConcurrentBag<UserOutcome>();
        var excludedCount = 0;

        var options = new ParallelOptions
        {
            MaxDegreeOfParallelism = Math.Max(1, _opt.MaxConcurrency * 2),
            CancellationToken = ct
        };

        await Parallel.ForEachAsync(users, options, async (u, token) =>
        {
            if (excluded.Contains(u.Mail) || excluded.Contains(u.Upn)
                || (excludePattern is not null && excludePattern.IsMatch(u.Upn)))
            {
                Interlocked.Increment(ref excludedCount);
                return;
            }

            var purpose = await _graph.GetMailboxPurposeAsync(u.Id, token);

            if (purpose is null)
            {
                // No mailbox provisioned. Expected for 27 accounts in this tenant — report
                // as its own class so it never pollutes the failure list night after night.
                noMailbox.Add(new UserOutcome
                {
                    UserEmail = u.Mail,
                    Reason = nameof(FailureReason.MailboxNotFound),
                    Message = u.DisplayName
                });
                return;
            }

            if (!purposes.Contains(purpose, StringComparer.OrdinalIgnoreCase))
            {
                Interlocked.Increment(ref excludedCount);
                return;
            }

            keep.Add(new RosterTarget(u.Mail, u.Id, u.DisplayName));
        });

        report.NoMailbox.AddRange(noMailbox.OrderBy(o => o.UserEmail, StringComparer.OrdinalIgnoreCase));
        report.Totals.NoMailbox = report.NoMailbox.Count;
        report.Totals.Excluded = excludedCount;

        return (keep.OrderBy(t => t.Mail, StringComparer.OrdinalIgnoreCase).ToList(), "ActiveUsers");
    }
}

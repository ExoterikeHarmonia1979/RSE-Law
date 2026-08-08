using Company.Function.GraphSubs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Company.Function;

/// <summary>
/// The nightly job that keeps Outlook mail subscriptions alive for every active mailbox.
///
///   Timer 22:00 local -> reconcile all active users -> create missing -> renew expiring
///                     -> repair broken -> republish the arrUsers projection -> email summary
///
/// Replaces the "Sched Renew Graph API Subscription" Power Automate flow. Two behaviours are
/// deliberate departures from it: failures are never swallowed, and a deleted subscription
/// always takes its partner topic with it.
///
/// The NCRONTAB below is 22:00 in the app's local time, which requires
/// WEBSITE_TIME_ZONE = "Pacific Standard Time" (Windows) or TZ = "America/Los_Angeles"
/// (Linux). Without it the schedule is UTC and drifts by an hour at every DST boundary.
/// </summary>
public class GraphSubNightly
{
    private readonly ReconcileEngine _engine;
    private readonly RunNotifier _notifier;
    private readonly ILogger<GraphSubNightly> _logger;

    public GraphSubNightly(ReconcileEngine engine, RunNotifier notifier, ILogger<GraphSubNightly> logger)
    {
        _engine = engine;
        _notifier = notifier;
        _logger = logger;
    }

    [Function("GraphSubNightly")]
    public async Task RunAsync(
        [TimerTrigger("0 0 22 * * *")] TimerInfo timer,
        CancellationToken ct)
    {
        var report = await ExecuteAsync(new ReconcileRequest { DryRun = false }, ct);

        if (report.FatalError is not null)
            throw new InvalidOperationException(
                $"GraphSubNightly run {report.RunId} failed: {report.FatalError}");
    }

    /// <summary>Manual trigger for the same work, for cutover and for re-running a bad night.</summary>
    [Function("GraphSubNightlyManual")]
    public async Task<IActionResult> RunManualAsync(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "graphsubs/nightly")] HttpRequest req,
        CancellationToken ct)
    {
        var dryRun = !string.Equals(req.Query["dryRun"], "false", StringComparison.OrdinalIgnoreCase);
        var report = await ExecuteAsync(new ReconcileRequest { DryRun = dryRun }, ct);
        return new OkObjectResult(report);
    }

    /// <summary>
    /// Runs the reconcile and reports it. The notification is sent in a finally block so a
    /// crash mid-run still produces an email — silence is the one outcome nobody notices.
    /// </summary>
    private async Task<ReconcileReport> ExecuteAsync(ReconcileRequest request, CancellationToken ct)
    {
        ReconcileReport report = new() { DryRun = request.DryRun };

        try
        {
            report = await _engine.RunAsync(request, ct);
        }
        catch (Exception ex)
        {
            report.FatalError = $"{ex.GetType().Name}: {ex.Message}";
            report.FinishedUtc = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "GraphSubNightly run {RunId} threw.", report.RunId);
        }
        finally
        {
            await _notifier.SendAsync(report, CancellationToken.None);

            _logger.LogInformation(
                "GraphSubNightly {RunId} {Outcome}: active {Before}->{After}, created {Created}, " +
                "renewed {Renewed}, repaired {Repaired}, failed {Failed}, noMailbox {NoMailbox}, " +
                "duration {Seconds:F1}s",
                report.RunId, report.Outcome, report.Totals.ActiveBefore, report.Totals.ActiveAfter,
                report.Totals.Created, report.Totals.Renewed, report.Totals.Repaired,
                report.Totals.Failed, report.Totals.NoMailbox, report.DurationSeconds);
        }

        return report;
    }
}

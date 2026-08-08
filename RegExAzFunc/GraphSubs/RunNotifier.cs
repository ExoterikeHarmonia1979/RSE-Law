using System.Net;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Company.Function.GraphSubs;

/// <summary>
/// Emails the nightly run summary. Sent on every run, success or failure — a green run that
/// says nothing is indistinguishable from a job that never fired.
///
/// This cannot report that the job failed to *start*, so it is paired with an Azure Monitor
/// "no successful run in 25 hours" alert; see docs/GraphSubscriptions.md.
/// </summary>
public sealed class RunNotifier
{
    private readonly GraphApiClient _graph;
    private readonly GraphSubOptions _opt;
    private readonly ILogger<RunNotifier> _log;

    public RunNotifier(GraphApiClient graph, IOptions<GraphSubOptions> opt, ILogger<RunNotifier> log)
    {
        _graph = graph;
        _opt = opt.Value;
        _log = log;
    }

    public async Task SendAsync(ReconcileReport report, CancellationToken ct = default)
    {
        try
        {
            await _graph.SendMailAsync(Subject(report), Body(report), ct);
        }
        catch (Exception ex)
        {
            // Swallow: notification failure must not mask the run's real outcome.
            _log.LogError(ex, "Failed to send run notification for {RunId}.", report.RunId);
        }
    }

    public string Subject(ReconcileReport r)
    {
        if (r.FatalError is not null)
            return $"[RSE GraphSubs] FAILED — {Truncate(r.FatalError, 80)}";

        if (r.SecretWarning)
            return $"[RSE GraphSubs] SECRET EXPIRES IN {Math.Floor(r.SecretDaysRemaining!.Value)} DAYS — " +
                   $"{r.Totals.ActiveAfter} active, {r.Totals.Failed} failed";

        if (r.Totals.Failed > 0)
            return $"[RSE GraphSubs] {r.Totals.Failed} FAILED — {r.Totals.ActiveAfter} active, " +
                   $"{r.Totals.Created} created, {r.Totals.Renewed} renewed";

        return $"[RSE GraphSubs] OK — {r.Totals.ActiveAfter} active, {r.Totals.Created} created, " +
               $"{r.Totals.Renewed} renewed";
    }

    private string Body(ReconcileReport r)
    {
        var sb = new StringBuilder();
        sb.Append("<html><body style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px\">");
        sb.Append($"<h2>Graph mail subscriptions — {WebUtility.HtmlEncode(r.Outcome)}</h2>");

        if (r.FatalError is not null)
            sb.Append($"<p style=\"color:#b00\"><b>Fatal error:</b> {WebUtility.HtmlEncode(r.FatalError)}</p>");

        if (r.SecretExpiryUnknown)
            sb.Append("<p style=\"color:#b00\"><b>Credential expiry is unknown.</b> The Key Vault secret has " +
                      "no <code>exp</code> attribute, so expiry cannot be monitored. Set it to the app " +
                      "registration's secret end date.</p>");
        else if (r.SecretWarning)
            sb.Append($"<p style=\"color:#b00\"><b>Client secret expires in " +
                      $"{Math.Floor(r.SecretDaysRemaining!.Value)} day(s).</b><br>" +
                      "Rotate: app registration <i>SharePoint Exchange Event Grid Graph API</i>, client " +
                      $"<code>{WebUtility.HtmlEncode(r.ClientId)}</code>.<br>" +
                      "<code>az ad app credential reset --id &lt;clientId&gt; --append --years 2</code> " +
                      "(<code>--append</code> matters — without it every existing secret is revoked), " +
                      "then update the Key Vault secret <b>and its <code>exp</code> attribute</b>.</p>");

        sb.Append("<h3>Summary</h3><table cellpadding=\"4\" style=\"border-collapse:collapse\">");
        Row(sb, "Run id", r.RunId);
        Row(sb, "Started (UTC)", r.StartedUtc.ToString("u"));
        Row(sb, "Duration", $"{r.DurationSeconds:F1}s");
        Row(sb, "Mode", r.DryRun ? "DRY RUN — no changes made" : "live");
        Row(sb, "Roster source", r.RosterSource);
        Row(sb, "Topic naming", r.TopicNaming);
        Row(sb, "Active before → after", $"{r.Totals.ActiveBefore} → {r.Totals.ActiveAfter}");
        Row(sb, "Created", r.Totals.Created.ToString());
        Row(sb, "Renewed", r.Totals.Renewed.ToString());
        Row(sb, "Repaired", r.Totals.Repaired.ToString());
        Row(sb, "Skipped (not due)", r.Totals.Skipped.ToString());
        Row(sb, "Failed", r.Totals.Failed.ToString());
        Row(sb, "Not in roster", r.Totals.Orphans.ToString());
        Row(sb, "No mailbox", r.Totals.NoMailbox.ToString());
        Row(sb, "Excluded", r.Totals.Excluded.ToString());
        sb.Append("</table>");

        Section(sb, "Failed", r.Failed, true);
        Section(sb, "Created", r.Created, false);
        Section(sb, "Repaired (subscription id changed)", r.Repaired, false);
        Section(sb, "Live but not in roster", r.Orphans, false);
        Section(sb, "Active accounts with no mailbox", r.NoMailbox, false);

        sb.Append($"<p style=\"color:#666;font-size:12px\">App {WebUtility.HtmlEncode(r.ClientId)} · " +
                  $"projection published: {r.ArrUsersPublished}</p>");
        sb.Append("</body></html>");
        return sb.ToString();
    }

    private static void Row(StringBuilder sb, string k, string v) =>
        sb.Append($"<tr><td style=\"color:#555\">{WebUtility.HtmlEncode(k)}</td>" +
                  $"<td><b>{WebUtility.HtmlEncode(v)}</b></td></tr>");

    private static void Section(StringBuilder sb, string title, List<UserOutcome> items, bool emphasise)
    {
        if (items.Count == 0) return;

        var colour = emphasise ? "#b00" : "#222";
        sb.Append($"<h3 style=\"color:{colour}\">{WebUtility.HtmlEncode(title)} ({items.Count})</h3><ul>");

        foreach (var i in items.Take(200))
        {
            var detail = i.Reason is null ? "" : $" — <i>{WebUtility.HtmlEncode(i.Reason)}</i>";
            var msg = string.IsNullOrWhiteSpace(i.Message) ? "" : $": {WebUtility.HtmlEncode(i.Message)}";
            sb.Append($"<li>{WebUtility.HtmlEncode(i.UserEmail)}{detail}{msg}</li>");
        }

        if (items.Count > 200) sb.Append($"<li>… and {items.Count - 200} more</li>");
        sb.Append("</ul>");
    }

    private static string Truncate(string s, int n) =>
        string.IsNullOrEmpty(s) ? "" : (s.Length <= n ? s : s[..n] + "…");
}

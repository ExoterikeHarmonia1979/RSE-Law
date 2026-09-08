using Company.Function.GraphSubs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// MsgReader needs the legacy code pages - .NET Core registers none of them, so reading a
// .msg whose content is Windows-1252 throws "No data is available for encoding 1252".
//
// This lived in EmlAttachmentNamesSkill's static initialiser, deliberately: e05123e put it
// there "so the skill cannot be deployed without it". That held while the skill was the only
// consumer. There are now three - EmlAttachmentNamesSkill, MsgProjection and DedupToken - and
// a static initialiser only runs when its own class is first touched, so any function reaching
// MsgReader in a worker process where the skill has not run gets no 1252.
//
// It surfaced on DedupTokenFunc: 7 of 40 real .msg blobs came back 422, every one of them a
// message ingest-key.py had keyed successfully. FromBytes swallows exceptions into a null
// token, so the crash was indistinguishable from a message with no headers. MsgProjection has
// the same exposure in the deployed .msg preview, where it shows as an intermittent 415 -
// intermittent because it only fails when the skill has not already run in that process.
//
// Registering here runs it once per host, before any function executes, which is the right
// scope for a process-wide encoding provider. The skill keeps its own call: RegisterProvider is
// idempotent, and leaving it costs nothing.
System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

// The isolated-worker Application Insights provider installs a default filter rule that drops
// everything below Warning, so ILogger.LogInformation from function code never reaches App
// Insights — only the host's own "Executing/Executed" traces do. Removing the rule lets the
// GraphSubNightly run summary through, which the "no successful run in 25h" alert depends on.
builder.Logging.Services.Configure<LoggerFilterOptions>(options =>
{
    var defaultRule = options.Rules.FirstOrDefault(rule =>
        rule.ProviderName == "Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider");

    if (defaultRule is not null)
        options.Rules.Remove(defaultRule);
});

// --- Graph mail-subscription automation ------------------------------------
builder.Services.Configure<GraphSubOptions>(
    builder.Configuration.GetSection(GraphSubOptions.SectionName));

builder.Services.AddSingleton<GraphCredentialProvider>();
builder.Services.AddSingleton<SubscriptionStateStore>();
builder.Services.AddSingleton<ReconcileEngine>();
builder.Services.AddSingleton<RunNotifier>();

builder.Services.AddHttpClient<GraphApiClient>(c => c.Timeout = TimeSpan.FromSeconds(100));
builder.Services.AddHttpClient<EventGridArmClient>(c => c.Timeout = TimeSpan.FromSeconds(100));

builder.Build().Run();

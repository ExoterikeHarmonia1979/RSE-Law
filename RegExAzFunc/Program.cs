using Company.Function.GraphSubs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

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

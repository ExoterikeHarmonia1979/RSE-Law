using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Company.Function.GraphSubs;

/// <summary>
/// Issues Graph and ARM tokens for the app registration that owns the mail subscriptions,
/// and reports how long its client secret has left.
///
/// Two different identities are in play and conflating them breaks everything:
///   * the OWNING app (<see cref="GraphSubOptions.ClientId"/>) — used for all Graph calls,
///     because Graph only returns and mutates subscriptions created by the same appId;
///   * the Function App's own managed identity — used only to read Key Vault and to call ARM.
/// </summary>
public sealed class GraphCredentialProvider
{
    public const string GraphScope = "https://graph.microsoft.com/.default";
    public const string ArmScope = "https://management.azure.com/.default";

    private readonly GraphSubOptions _opt;
    private readonly ILogger<GraphCredentialProvider> _log;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private ClientSecretCredential? _owner;
    private ClientSecretCredential? _notifier;
    private DefaultAzureCredential? _local;
    private bool _warnedAboutSharedSender;

    /// <summary>Expiry of the client secret, from the Key Vault secret's <c>exp</c>
    /// attribute. Null means it could not be determined — which must be surfaced as a
    /// warning, never treated as "plenty of time".</summary>
    public DateTimeOffset? SecretExpiresOn { get; private set; }

    public bool SecretExpiryUnknown { get; private set; } = true;

    public GraphCredentialProvider(IOptions<GraphSubOptions> opt, ILogger<GraphCredentialProvider> log)
    {
        _opt = opt.Value;
        _log = log;
    }

    private DefaultAzureCredential LocalIdentity => _local ??= new DefaultAzureCredential();

    /// <summary>Token for the owning app registration. Azure.Identity caches internally.</summary>
    public async Task<string> GetGraphTokenAsync(CancellationToken ct = default)
    {
        var cred = await GetOwnerCredentialAsync(ct);
        var token = await cred.GetTokenAsync(new TokenRequestContext(new[] { GraphScope }), ct);
        return token.Token;
    }

    /// <summary>
    /// ARM token. Uses the Function App's own identity, not the owning app — partner topic
    /// and event subscription management is Azure RBAC, unrelated to Graph subscription
    /// ownership.
    /// </summary>
    public async Task<string> GetArmTokenAsync(CancellationToken ct = default)
    {
        var token = await LocalIdentity.GetTokenAsync(new TokenRequestContext(new[] { ArmScope }), ct);
        return token.Token;
    }

    /// <summary>
    /// Token for sending the summary email. Uses the dedicated notifier app when configured,
    /// so that Mail.Send can be locked to one mailbox with an Exchange application access
    /// policy — such a policy applied to the archive app would also cut off its Mail.Read
    /// across every other mailbox and break subscription management entirely.
    /// </summary>
    public async Task<string> GetNotifyTokenAsync(CancellationToken ct = default)
    {
        if (!_opt.HasDedicatedNotifier)
        {
            if (!_warnedAboutSharedSender)
            {
                _warnedAboutSharedSender = true;
                _log.LogWarning(
                    "No dedicated notifier app configured; sending as the archive app {ClientId}, " +
                    "whose Mail.Send is tenant-wide and cannot safely be scoped. Set " +
                    "GraphSub__NotifierClientId to narrow it.", _opt.ClientId);
            }
            return await GetGraphTokenAsync(ct);
        }

        var cred = await GetNotifierCredentialAsync(ct);
        var token = await cred.GetTokenAsync(new TokenRequestContext(new[] { GraphScope }), ct);
        return token.Token;
    }

    private async Task<ClientSecretCredential> GetNotifierCredentialAsync(CancellationToken ct)
    {
        if (_notifier is not null) return _notifier;

        await _gate.WaitAsync(ct);
        try
        {
            if (_notifier is not null) return _notifier;

            string secret;
            if (!string.IsNullOrWhiteSpace(_opt.SecretKeyVaultUri))
            {
                var client = new SecretClient(new Uri(_opt.SecretKeyVaultUri), LocalIdentity);
                var kv = await client.GetSecretAsync(_opt.NotifierSecretName, cancellationToken: ct);
                secret = kv.Value.Value;
            }
            else
            {
                secret = _opt.NotifierClientSecretFallback!;
            }

            _notifier = new ClientSecretCredential(_opt.TenantId, _opt.NotifierClientId, secret);
            return _notifier;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<ClientSecretCredential> GetOwnerCredentialAsync(CancellationToken ct)
    {
        if (_owner is not null) return _owner;

        await _gate.WaitAsync(ct);
        try
        {
            if (_owner is not null) return _owner;

            var secret = await ResolveSecretAsync(ct);
            _owner = new ClientSecretCredential(_opt.TenantId, _opt.ClientId, secret);
            return _owner;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<string> ResolveSecretAsync(CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(_opt.SecretKeyVaultUri))
        {
            var client = new SecretClient(new Uri(_opt.SecretKeyVaultUri), LocalIdentity);
            KeyVaultSecret secret = await client.GetSecretAsync(_opt.SecretName, cancellationToken: ct);

            SecretExpiresOn = secret.Properties.ExpiresOn;
            SecretExpiryUnknown = SecretExpiresOn is null;

            if (SecretExpiryUnknown)
                _log.LogWarning(
                    "Key Vault secret {Name} has no 'exp' attribute set, so credential expiry " +
                    "cannot be monitored. Set it to the app registration's secret end date.",
                    _opt.SecretName);

            return secret.Value;
        }

        if (!string.IsNullOrWhiteSpace(_opt.ClientSecretFallback))
        {
            _log.LogWarning(
                "Using GraphSub__ClientSecretFallback from app settings. This is for local " +
                "development only — configure GraphSub__SecretKeyVaultUri in Azure.");
            SecretExpiresOn = null;
            SecretExpiryUnknown = true;
            return _opt.ClientSecretFallback;
        }

        throw new InvalidOperationException(
            "No client secret available: set GraphSub__SecretKeyVaultUri (preferred) or " +
            "GraphSub__ClientSecretFallback.");
    }

    /// <summary>Days until the secret expires, or null if unknown.</summary>
    public double? SecretDaysRemaining(DateTimeOffset now) =>
        SecretExpiresOn is null ? null : (SecretExpiresOn.Value - now).TotalDays;
}

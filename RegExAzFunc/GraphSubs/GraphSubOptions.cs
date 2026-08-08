namespace Company.Function.GraphSubs;

/// <summary>
/// Configuration for the Graph mail-subscription automation, bound from
/// <c>GraphSub__*</c> app settings.
///
/// The client secret is never a setting value — <see cref="SecretKeyVaultUri"/> and
/// <see cref="SecretName"/> point at Key Vault, and the secret's <c>exp</c> attribute is
/// what the expiry warning reads. <see cref="ClientSecretFallback"/> exists only so the
/// project runs locally without a vault; it is logged as a warning when used.
/// </summary>
public sealed class GraphSubOptions
{
    public const string SectionName = "GraphSub";

    // --- identity -----------------------------------------------------------
    /// <summary>App registration that OWNS the existing subscriptions. Graph scopes
    /// subscriptions to their creating app, so this must not change.</summary>
    public string ClientId { get; set; } = "";
    public string TenantId { get; set; } = "";
    public string? SecretKeyVaultUri { get; set; }
    public string SecretName { get; set; } = "GraphSubClientSecret";
    public string? ClientSecretFallback { get; set; }

    // --- Event Grid target --------------------------------------------------
    public string AzureSubscriptionId { get; set; } = "";
    public string ResourceGroup { get; set; } = "";
    public string PartnerTopic { get; set; } = "GETopicRSEShared";
    public string Location { get; set; } = "eastus";
    /// <summary><c>Shared</c> (all mailboxes on <see cref="PartnerTopic"/>) or
    /// <c>PerUser</c> (legacy <c>GETopic&lt;name&gt;</c> naming, kept for reconciling and
    /// rolling back the pre-migration world).</summary>
    public string TopicNaming { get; set; } = "Shared";
    public string ServiceBusQueueResourceId { get; set; } = "";
    /// <summary>Optional blob container URL for Event Grid dead-lettering. Unset today,
    /// which means failed deliveries are discarded after 30 attempts / 24h.</summary>
    public string? DeadLetterContainerResourceId { get; set; }

    // --- subscription behaviour --------------------------------------------
    public string ClientState { get; set; } = "secretClientValue";
    /// <summary>Renew to now + this many days. Max allowed is 7 (10,080 min); 6 gives six
    /// consecutive missed nightly runs before anything actually lapses.</summary>
    public int RenewToDays { get; set; } = 6;
    /// <summary>Renew anything expiring within this many hours.</summary>
    public int RenewLeadHours { get; set; } = 72;
    public int MaxConcurrency { get; set; } = 4;

    // --- roster -------------------------------------------------------------
    /// <summary>Skip members of this Entra group (service accounts, carve-outs).</summary>
    public string? ExcludeGroupId { get; set; }
    /// <summary>Regex matched against UPN; matches are skipped.</summary>
    public string? ExcludeUpnPattern { get; set; }
    /// <summary>Mailbox purposes to subscribe. <c>shared</c> is excluded by default —
    /// the fax line, matters@ and records@ are a business call, not a technical one.</summary>
    public string IncludeMailboxPurposes { get; set; } = "user";

    // --- projection ---------------------------------------------------------
    /// <summary>Container for the published <c>arrUsers</c> projection.</summary>
    public string ProjectionContainer { get; set; } = "config";
    public string ProjectionBlob { get; set; } = "arrUsers.json";

    // --- notification -------------------------------------------------------
    public string NotifyTo { get; set; } = "";
    public string NotifyFrom { get; set; } = "";
    public int SecretWarnDays { get; set; } = 7;

    /// <summary>
    /// Separate app registration used *only* to send the summary email.
    ///
    /// The archive app cannot be the sender: restricting Mail.Send with an Exchange
    /// ApplicationAccessPolicy would also restrict its Mail.Read/MailboxSettings access, and
    /// it must reach every mailbox in the tenant. A dedicated registration holding nothing
    /// but Mail.Send can be locked to the sender mailbox without touching the archive.
    ///
    /// Leave empty to fall back to the owning app (unscoped send).
    /// </summary>
    public string? NotifierClientId { get; set; }
    public string NotifierSecretName { get; set; } = "GraphSubNotifierSecret";
    public string? NotifierClientSecretFallback { get; set; }

    public bool HasDedicatedNotifier =>
        !string.IsNullOrWhiteSpace(NotifierClientId)
        && (!string.IsNullOrWhiteSpace(SecretKeyVaultUri)
            || !string.IsNullOrWhiteSpace(NotifierClientSecretFallback));

    public string[] NotifyRecipients() => NotifyTo
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    public string[] IncludedPurposes() => IncludeMailboxPurposes
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    public bool UseSharedTopic =>
        TopicNaming.Equals("Shared", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Partner topic for a mailbox. The PerUser rule reproduces the legacy flow exactly —
    /// strip <c>@ - .</c> and the literal <c>rselawcom</c> — because a subscription on a
    /// differently-named topic delivers where nothing is listening.
    /// </summary>
    public string TopicNameFor(string email)
    {
        if (UseSharedTopic) return PartnerTopic;

        var local = email.Replace("@", "").Replace("-", "").Replace(".", "");
        local = System.Text.RegularExpressions.Regex.Replace(
            local, "rselawcom", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return "GETopic" + local;
    }

    public string NotificationUrlFor(string email) =>
        $"EventGrid:?azuresubscriptionid={AzureSubscriptionId}" +
        $"&resourcegroup={ResourceGroup}" +
        $"&partnertopic={TopicNameFor(email)}" +
        $"&location={Location}";

    public void Validate()
    {
        var missing = new List<string>();
        if (string.IsNullOrWhiteSpace(ClientId)) missing.Add(nameof(ClientId));
        if (string.IsNullOrWhiteSpace(TenantId)) missing.Add(nameof(TenantId));
        if (string.IsNullOrWhiteSpace(AzureSubscriptionId)) missing.Add(nameof(AzureSubscriptionId));
        if (string.IsNullOrWhiteSpace(ResourceGroup)) missing.Add(nameof(ResourceGroup));
        if (string.IsNullOrWhiteSpace(ServiceBusQueueResourceId)) missing.Add(nameof(ServiceBusQueueResourceId));
        if (missing.Count > 0)
            throw new InvalidOperationException(
                "Missing required GraphSub settings: " + string.Join(", ", missing));
    }
}

using System.Text.Json.Serialization;

namespace Company.Function;

internal sealed record MsgAttachment(string Name, byte[] Data)
{
    public long Size => Data.LongLength;
}

/// <summary>
/// The parts of a .msg this app needs, behind an interface so the projection is
/// testable without a real compound file. Real .msg bytes in this container are
/// client correspondence and are never committed as fixtures.
/// </summary>
internal interface IMsgMessage
{
    string Subject { get; }
    string From { get; }
    IReadOnlyList<string> To { get; }
    IReadOnlyList<string> Cc { get; }
    DateTimeOffset? Sent { get; }
    string? BodyHtml { get; }
    string BodyText { get; }
    IReadOnlyList<MsgAttachment> Attachments { get; }
}

internal sealed class PreviewAttachmentDto
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("sizeBytes")] public long SizeBytes { get; set; }
}

/// <summary>The preview JSON shape. Property names are pinned by attribute because
/// models/IEmailItem.ts reads them literally.</summary>
internal sealed class PreviewDto
{
    [JsonPropertyName("subject")] public string Subject { get; set; } = "";
    [JsonPropertyName("from")] public string From { get; set; } = "";
    [JsonPropertyName("to")] public string[] To { get; set; } = Array.Empty<string>();
    [JsonPropertyName("cc")] public string[] Cc { get; set; } = Array.Empty<string>();
    [JsonPropertyName("date")] public string Date { get; set; } = "";
    [JsonPropertyName("htmlBody")] public string? HtmlBody { get; set; }
    [JsonPropertyName("textBody")] public string TextBody { get; set; } = "";
    [JsonPropertyName("attachments")] public PreviewAttachmentDto[] Attachments { get; set; } = Array.Empty<PreviewAttachmentDto>();
}

internal static class MsgProjection
{
    private static ReadOnlySpan<byte> Ole2Signature => [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

    /// <summary>Detects a .msg by its OLE2 compound-file header rather than by extension.
    /// The ingest derived blob names from subjects, so an extension is not evidence.</summary>
    internal static bool LooksLikeCompoundFile(ReadOnlySpan<byte> bytes) =>
        bytes.Length >= 8 && bytes[..8].SequenceEqual(Ole2Signature);

    internal static PreviewDto ToPreview(IMsgMessage message, Func<string, string> sanitizeHtml)
    {
        return new PreviewDto
        {
            Subject = message.Subject,
            From = message.From,
            To = message.To.ToArray(),
            Cc = message.Cc.ToArray(),
            Date = message.Sent?.ToString("o") ?? "",
            HtmlBody = message.BodyHtml == null ? null : sanitizeHtml(message.BodyHtml),
            TextBody = message.BodyText,
            Attachments = message.Attachments
                .Select(a => new PreviewAttachmentDto { Name = a.Name, SizeBytes = a.Size })
                .ToArray()
        };
    }

    /// <summary>Guarded form of <see cref="Read"/>. A blob can pass <see cref="LooksLikeCompoundFile"/>
    /// on its first 8 bytes and still be truncated or corrupt beyond that header - MsgReader throws in
    /// that case. Mirrors the try/catch EmlPreviewFunc.LoadMessage already applies around
    /// MimeMessage.Load, so a bad .msg degrades the same way a bad .eml does instead of a bare 500.
    /// The exception comes back through <paramref name="error"/> - not just swallowed - so the caller
    /// can log it the same way LoadMessage logs the .eml parse failure it mirrors; .msg is 52% of this
    /// archive and, unlike the .eml path, has no field data yet.</summary>
    internal static bool TryRead(byte[] bytes, out IMsgMessage? message, out Exception? error)
    {
        try
        {
            message = Read(bytes);
            error = null;
            return true;
        }
        catch (Exception ex)
        {
            message = null;
            error = ex;
            return false;
        }
    }

    /// <summary>Adapter over MsgReader. Not unit-tested — it is a thin mapping onto a
    /// third-party parser, verified against real blobs through the local Functions host.</summary>
    internal static IMsgMessage Read(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes);
        using var message = new MsgReader.Outlook.Storage.Message(stream);

        var attachments = new List<MsgAttachment>();
        foreach (object obj in message.Attachments)
        {
            if (obj is MsgReader.Outlook.Storage.Attachment a && a.Data != null)
            {
                attachments.Add(new MsgAttachment(a.FileName ?? "attachment", a.Data));
            }
        }

        return new MsgReaderMessage
        {
            Subject = message.Subject ?? "",
            From = message.Sender?.DisplayName ?? message.Sender?.Email ?? "",
            To = RecipientsOfType(message, MsgReader.Outlook.RecipientType.To),
            Cc = RecipientsOfType(message, MsgReader.Outlook.RecipientType.Cc),
            Sent = message.SentOn,
            BodyHtml = string.IsNullOrWhiteSpace(message.BodyHtml) ? null : message.BodyHtml,
            BodyText = message.BodyText ?? "",
            Attachments = attachments
        };
    }

    /// <summary>One array entry per recipient, matching how the .eml path renders
    /// message.To/.Cc (EmlPreviewFunc.cs ServePreview). GetEmailRecipients(type, ...) was
    /// tried first and rejected: verified against real blobs, it returns a single formatted
    /// string covering every recipient of that type, so a message with several To/Cc
    /// addresses collapsed into one array entry instead of several - a defect the .eml path
    /// does not have. message.Recipients filtered by Type does not collapse them.</summary>
    private static string[] RecipientsOfType(MsgReader.Outlook.Storage.Message message, MsgReader.Outlook.RecipientType type) =>
        message.Recipients
            .Where(r => r.Type == type)
            .Select(r => string.IsNullOrWhiteSpace(r.DisplayName) ? r.Email ?? "" : $"{r.DisplayName} <{r.Email}>")
            .Where(s => s.Length > 0)
            .ToArray();

    private sealed class MsgReaderMessage : IMsgMessage
    {
        public string Subject { get; init; } = "";
        public string From { get; init; } = "";
        public IReadOnlyList<string> To { get; init; } = Array.Empty<string>();
        public IReadOnlyList<string> Cc { get; init; } = Array.Empty<string>();
        public DateTimeOffset? Sent { get; init; }
        public string? BodyHtml { get; init; }
        public string BodyText { get; init; } = "";
        public IReadOnlyList<MsgAttachment> Attachments { get; init; } = Array.Empty<MsgAttachment>();
    }
}

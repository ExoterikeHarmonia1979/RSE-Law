using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using MimeKit;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Company.Function;

/// <summary>
/// Azure AI Search custom skill (WebApi skill): receives the raw .eml file
/// via /document/file_data and returns the attachment file names, so the
/// matters-eml-index can populate its attachment_names field.
/// </summary>
public class EmlAttachmentNamesSkill
{
    public class SkillRequest
    {
        [JsonPropertyName("values")]
        public List<SkillRecord> Values { get; set; } = new();
    }

    public class SkillRecord
    {
        [JsonPropertyName("recordId")]
        public string RecordId { get; set; } = "";

        [JsonPropertyName("data")]
        public SkillRecordData Data { get; set; } = new();
    }

    public class SkillRecordData
    {
        // file_data arrives as { "$type": "file", "data": "<base64>" }
        [JsonPropertyName("file_data")]
        public FileData? FileData { get; set; }
    }

    public class FileData
    {
        [JsonPropertyName("data")]
        public string? Data { get; set; }
    }

    private readonly ILogger<EmlAttachmentNamesSkill> _logger;

    public EmlAttachmentNamesSkill(ILogger<EmlAttachmentNamesSkill> logger)
    {
        _logger = logger;
    }

    [Function("EmlAttachmentNamesSkill")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequest req)
    {
        // Deserialise straight from the request stream. Reading it into a string first
        // meant holding the whole payload twice: once as a .NET string (UTF-16, so double
        // the bytes) and again as the parsed object. file_data arrives base64-encoded, so
        // a batch of large messages is a very big body, and on a 2048 MB instance that
        // buffering is what pushed requests past the skill's 230s timeout - Azure AI Search
        // then dropped the connection, which surfaces here as "Broken pipe" and at the
        // indexer as "Could not execute skill because the Web Api request failed".
        SkillRequest? request;
        try
        {
            request = await JsonSerializer.DeserializeAsync<SkillRequest>(req.Body);
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult("Malformed custom skill payload.");
        }

        if (request?.Values == null || request.Values.Count == 0)
        {
            return new BadRequestObjectResult("Expected a 'values' array.");
        }

        var results = request.Values.Select(record =>
        {
            var (names, sentDate) = ParseMessage(record);
            return new
            {
                recordId = record.RecordId,
                data = new { attachmentNames = names, sentDate },
                errors = (object?)null,
                warnings = (object?)null
            };
        });

        return new OkObjectResult(new { values = results });
    }

    static EmlAttachmentNamesSkill()
    {
        // .msg carries a MAPI code page - Windows-1252 and friends - and .NET Core
        // dropped the legacy code page tables from the base library. Without this,
        // MsgReader throws "No data is available for encoding 1252" the moment it reads
        // an attachment.
        //
        // Registered here rather than in Program.cs so the skill cannot be deployed
        // without it. The failure mode is nasty: the exception is caught below and
        // logged as a warning, so every ingested message would come back with blank
        // attachment_names and sent_date - looking like an unsupported format rather
        // than a missing encoding provider, and only at index time, never at build.
        System.Text.Encoding.RegisterProvider(
            System.Text.CodePagesEncodingProvider.Instance);
    }

    // An OLE compound file starts with this. .msg is one; .eml never is.
    private static readonly byte[] CfbMagic =
        { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

    private static bool LooksLikeMsg(byte[] bytes)
    {
        if (bytes.Length < CfbMagic.Length) return false;
        for (int i = 0; i < CfbMagic.Length; i++)
        {
            if (bytes[i] != CfbMagic[i]) return false;
        }
        return true;
    }

    /// <summary>
    /// Outlook .msg, which is what the archive ingest writes: Purview's eDiscovery export
    /// produces .msg directly, and Azure AI Search indexes it natively. Without this the
    /// two fields this skill exists to populate would simply be blank for every ingested
    /// message, which looks like missing data rather than an unhandled format.
    /// </summary>
    private (List<string> Names, string? SentDate) ParseMsg(byte[] bytes, string recordId)
    {
        var names = new List<string>();
        string? sentDate = null;

        using var stream = new MemoryStream(bytes);
        using var msg = new MsgReader.Outlook.Storage.Message(stream);

        // Prefer the transport headers, for the same reason ingest-key.py does: they are
        // the message's own record of itself, and reading them keeps .msg and .eml
        // agreeing on sent_date instead of drifting apart by a timezone or a property.
        var raw = msg.TransportMessageHeaders;
        if (!string.IsNullOrWhiteSpace(raw))
        {
            try
            {
                var parsed = MimeMessage.Load(
                    new MemoryStream(System.Text.Encoding.UTF8.GetBytes(raw + "\r\n\r\n")));
                if (parsed.Date != DateTimeOffset.MinValue)
                {
                    sentDate = parsed.Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Header parse failed for {RecordId}, falling back", recordId);
            }
        }

        // Internal Outlook-to-Outlook mail never traversed SMTP and carries no transport
        // headers at all - roughly a quarter of this archive - so fall back to the MAPI
        // submit time rather than reporting no date.
        if (sentDate is null && msg.SentOn.HasValue)
        {
            sentDate = msg.SentOn.Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        }

        foreach (var attachment in msg.Attachments)
        {
            string? name = attachment switch
            {
                // Inline images (signature logos) are excluded to match the .eml branch,
                // which counts only Content-Disposition: attachment.
                MsgReader.Outlook.Storage.Attachment a => a.IsInline ? null : a.FileName,
                MsgReader.Outlook.Storage.Message embedded => embedded.FileName,
                _ => null
            };
            if (!string.IsNullOrWhiteSpace(name) && !names.Contains(name))
            {
                names.Add(name);
            }
        }

        return (names, sentDate);
    }

    private (List<string> Names, string? SentDate) ParseMessage(SkillRecord record)
    {
        var names = new List<string>();
        string? sentDate = null;
        var base64 = record.Data.FileData?.Data;
        if (string.IsNullOrEmpty(base64))
        {
            return (names, sentDate);
        }

        try
        {
            var bytes = Convert.FromBase64String(base64);

            // Dispatch on content, not on a file name - the skill only ever receives
            // bytes, and the blob extension is not in the payload.
            if (LooksLikeMsg(bytes))
            {
                return ParseMsg(bytes, record.RecordId);
            }

            using var stream = new MemoryStream(bytes);
            var message = MimeMessage.Load(stream);

            // The Date: header is the true sent time — unlike the indexer's
            // metadata_creation_date, which carries the EVENT date for meeting
            // invites. The index sorts and filters on this value (sent_date).
            if (message.Date != DateTimeOffset.MinValue)
            {
                sentDate = message.Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
            }

            // message.Attachments = entities with Content-Disposition: attachment.
            // Inline images (signature logos etc.) are deliberately excluded,
            // matching what Outlook counts as an attachment.
            foreach (MimeEntity attachment in message.Attachments)
            {
                string? name = attachment.ContentDisposition?.FileName
                    ?? attachment.ContentType?.Name;
                if (!string.IsNullOrWhiteSpace(name) && !names.Contains(name))
                {
                    names.Add(name);
                }
            }
        }
        catch (Exception ex)
        {
            // Corrupt or unrecognised input: return no data rather than failing the whole
            // indexer batch for one bad document. (.msg used to land here too, which is
            // why ingested mail would have had blank attachment_names and sent_date.)
            _logger.LogWarning(ex, "Could not parse message for record {RecordId}", record.RecordId);
        }

        return (names, sentDate);
    }
}

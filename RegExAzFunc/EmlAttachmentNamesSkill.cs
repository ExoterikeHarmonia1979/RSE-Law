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
        string requestBody = await new StreamReader(req.Body).ReadToEndAsync();
        SkillRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<SkillRequest>(requestBody);
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult("Malformed custom skill payload.");
        }

        if (request?.Values == null || request.Values.Count == 0)
        {
            return new BadRequestObjectResult("Expected a 'values' array.");
        }

        var results = request.Values.Select(record => new
        {
            recordId = record.RecordId,
            data = new { attachmentNames = ExtractNames(record) },
            errors = (object?)null,
            warnings = (object?)null
        });

        return new OkObjectResult(new { values = results });
    }

    private List<string> ExtractNames(SkillRecord record)
    {
        var names = new List<string>();
        var base64 = record.Data.FileData?.Data;
        if (string.IsNullOrEmpty(base64))
        {
            return names;
        }

        try
        {
            using var stream = new MemoryStream(Convert.FromBase64String(base64));
            var message = MimeMessage.Load(stream);

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
            // Non-MIME input (.msg, corrupt file): return no names rather than
            // failing the whole indexer batch for one bad document.
            _logger.LogWarning(ex, "Could not parse message for record {RecordId}", record.RecordId);
        }

        return names;
    }
}

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Company.Function;

/// <summary>
/// The k-token for a message, so the archive can name mail after the message rather than
/// after the mailbox copy it arrived in.
///
///   POST                      body: raw .eml/.msg bytes    -> one token
///   POST ?from=fields         body: [{id, messageId, sentDateTime}, ...] -> many tokens
///
/// Two routes because the callers can afford different things. The Logic App holds the
/// bytes already and must be exact - a wrong token there writes a mis-named blob. A sweep
/// walking 198,000 messages cannot fetch each one's MIME, and can afford to be wrong,
/// because a wrong token there only re-queues a message the pipeline then overwrites.
/// </summary>
public class DedupTokenFunc
{
    public class FieldsRequest
    {
        [JsonPropertyName("id")] public string Id { get; set; } = "";
        [JsonPropertyName("messageId")] public string? MessageId { get; set; }
        [JsonPropertyName("sentDateTime")] public string? SentDateTime { get; set; }
    }

    private readonly ILogger<DedupTokenFunc> _logger;

    public DedupTokenFunc(ILogger<DedupTokenFunc> logger) => _logger = logger;

    [Function("DedupTokenFunc")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequest req)
    {
        if (string.Equals(req.Query["from"], "fields", StringComparison.OrdinalIgnoreCase))
        {
            return await FromFields(req);
        }

        using var ms = new MemoryStream();
        await req.Body.CopyToAsync(ms);
        var (token, mid, sent) = DedupToken.FromBytes(ms.ToArray());
        if (token == null)
        {
            // Not an error the caller should retry: this message has no derivable identity
            // and never will. 422 tells the Logic App to fall back rather than stall.
            return new ObjectResult(new { error = "no Message-ID or Date" })
            { StatusCode = StatusCodes.Status422UnprocessableEntity };
        }
        return new OkObjectResult(new { token, messageId = mid, sentUtc = sent });
    }

    private async Task<IActionResult> FromFields(HttpRequest req)
    {
        List<FieldsRequest>? items;
        try
        {
            items = await JsonSerializer.DeserializeAsync<List<FieldsRequest>>(req.Body);
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult(new { error = "Malformed JSON payload." });
        }
        if (items == null) { return new BadRequestObjectResult(new { error = "Expected an array." }); }

        var results = items.Select(i => new
        {
            id = i.Id,
            // The same normalisation the bytes route uses. Only the source of the two
            // inputs differs, which is the whole point of sharing DedupToken.
            token = DedupToken.Key(DedupToken.CleanMid(i.MessageId),
                                   DedupToken.SentUtc(i.SentDateTime))
        }).ToList();

        return new OkObjectResult(results);
    }
}

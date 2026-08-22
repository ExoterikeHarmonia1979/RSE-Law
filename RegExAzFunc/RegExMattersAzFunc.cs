using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using RegExAzFunc;

namespace Company.Function;

public class RegExMattersAzFunc
{
    public class RegexRequest
    {
        public string strData { get; set; }

    }
    private readonly ILogger<RegExMattersAzFunc> _logger;

    /// <summary>
    /// The token as written, then the same token with leading/trailing punctuation removed.
    /// <para>
    /// Tokenising keeps '.' and '-' because case numbers need them internally
    /// (30-2023-01351580-CU-PO-NJC). That also means "100.238- Santa Rosa" tokenises to
    /// "100.238-", and every pattern here is anchored, so the trailing hyphen made the match
    /// fail and the mail was filed under UnsortedMatterCommunication instead of its matter.
    /// "matter-number- description" is a common way to write a subject line.
    /// </para>
    /// <para>
    /// Only the ends are trimmed, never the interior, so hyphenated case numbers are
    /// unaffected. The untrimmed form is tried first so nothing that matches today can change
    /// what it matches.
    /// </para>
    /// </summary>
    private static IEnumerable<string> Candidates(string word)
    {
        yield return word;

        var trimmed = word.Trim('.', '-', '_');
        if (trimmed.Length > 0 && !string.Equals(trimmed, word, StringComparison.Ordinal))
            yield return trimmed;
    }

    public RegExMattersAzFunc(ILogger<RegExMattersAzFunc> logger)
    {
        _logger = logger;
    }

    [Function("RegExMattersAzFunc")]
    public async Task<IActionResult> Run([HttpTrigger(AuthorizationLevel.Anonymous, "get", "post")] HttpRequest req)
    {
        try
        {
            // 1. Read the raw body stream
            string requestBody = await new StreamReader(req.Body).ReadToEndAsync();

            // 2. Deserialize JSON
            var data = JsonSerializer.Deserialize<RegexRequest>(requestBody, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            // Validation for strData only (since we are hardcoding the patterns now)
            if (data == null || string.IsNullOrEmpty(data.strData))
            {
                return new BadRequestObjectResult("Please provide 'strData' in the request body.");
            }


            Match match;

            //Replace all special characters in data.strData except . and -
            data.strData = Regex.Replace(data.strData, @"[^\w.-]", " ");

            // Split the input string by any whitespace characters
            string[] words = data.strData.Split(new[] { ' ', '\t', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries);

            foreach (string word in words)
            {

                // 1. RSE File No
                foreach (string candidate in Candidates(word))
                foreach (string pattern in RSEFileNoPatterns.Patterns)
                {
                    match = Regex.Match(candidate, pattern);
                    if (match.Success)
                    {
                        return new OkObjectResult(new { match = match.Value, type = "RSE File No" });
                    }
                }
            }

            foreach (string word in words)
            {
                // 2. Case No / Claim No (values in these two columns share the same
                // shapes, so one shared, generalized pattern set covers both)
                foreach (string candidate in Candidates(word))
                foreach (string pattern in CaseClaimNoPatterns.Patterns)
                {
                    match = Regex.Match(candidate, pattern);
                    if (match.Success)
                    {
                        return new OkObjectResult(new { match = match.Value, type = "Case/Claim No" });
                    }
                }
            }



            // Nothing in the subject resolves to a matter.
            //
            // This used to be decided by a block of hand-written patterns - things like
            // @"\d\d\d\d\d\d\d" (any seven consecutive digits, unanchored) and @"\d\d.\d\d\d"
            // (the dot unescaped, so it matched "25X123" too). If one of them hit, the
            // message was declared Unsorted; if none did, this returned empty.
            //
            // That made the loose patterns the ONLY thing routing unresolvable mail into the
            // unsorted bucket, and an empty return means the workflow writes no blob at all -
            // so a subject too plain to trip even those patterns ("RE: Data Breach Callers")
            // was completed and archived nowhere. Measured at 0.7% of a 300-subject sample.
            //
            // The routing decision is now unconditional and does not depend on whether a
            // court reference or invoice number happened to look like a matter number.
            // Everything unresolvable lands in the unsorted bucket, where it is at least
            // stored and searchable.
            //
            // "UnsortedMatterCommunication" is a real row in the Matters Lookup list (item
            // 185), so the workflow resolves it like any other matter. It is deliberately NOT
            // treated as a real match there: If_No_Matter_Use_Folder_Hint overrides this
            // placeholder when the mailbox folder names a matter, which is how mail whose
            // subject says nothing still reaches the right place.
            return new OkObjectResult(new { match = "UnsortedMatterCommunication", type = "Unsorted" });
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult("Malformed JSON payload.");
        }
        catch (RegexMatchTimeoutException)
        {
            return new StatusCodeResult(StatusCodes.Status408RequestTimeout);
        }
        catch (ArgumentException ex)
        {
            return new BadRequestObjectResult($"Invalid Regex Pattern: {ex.Message}");
        }
        catch (Exception ex)
        {
            // Generic catch for unexpected errors
            return new ObjectResult(new { error = ex.Message }) { StatusCode = 500 };
        }

    }
}
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
                foreach (string pattern in RSEFileNoPatterns.Patterns)
                {
                    match = Regex.Match(word, pattern);
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
                foreach (string pattern in CaseClaimNoPatterns.Patterns)
                {
                    match = Regex.Match(word, pattern);
                    if (match.Success)
                    {
                        return new OkObjectResult(new { match = match.Value, type = "Case/Claim No" });
                    }
                }
            }



            /*For  the following reg expressions match on any of these:

            \d\d.\d\d\d
        \d\d\d.\d\d\d
        \d\d.\d\d\d\d
        1\d-\d\d\d\d\d\d\d
        2\d-\d\d\d\d\d\d\d
        2\d-\d\d\d\d\d\d\d\d\d
        BEAZL\d\d\d\d\d\d\d\d\d\d\d\d
        \d\d\d\d\d\d\d
        \d\d\d\d\d\d\d\d\d\d
        \d\d\d\d\d\d\d\d\d\d\d
        \d\d-\d\d-\d\d\d\d\d\d
        \d\d\d\d\d\d-001
        \d\d.\d\d\d\d
        95A.\d\d\d
            */

            var patterns = new List<string>
{
   @"\d\d.\d\d\d",
@"\d\d\d.\d\d\d",
@"\d\d.\d\d\d\d",
@"1\d-\d\d\d\d\d\d\d",
@"2\d-\d\d\d\d\d\d\d",
@"2\d-\d\d\d\d\d\d\d\d\d",
@"BEAZL\d\d\d\d\d\d\d\d\d\d\d\d",
@"\d\d\d\d\d\d\d",
@"\d\d\d\d\d\d\d\d\d\d",
@"\d\d\d\d\d\d\d\d\d\d\d",
@"\d\d-\d\d-\d\d\d\d\d\d",
@"\d\d\d\d\d\d-001",
@"\d\d.\d\d\d\d",
@"95A.\d\d\d",
};

            foreach (string word in words)
            {
                foreach (string pattern in patterns)
                {
                    match = Regex.Match(word, pattern);
                    if (match.Success)
                    {
                        // Returns on the very first match it finds
                        return new OkObjectResult(new { match = "UnsortedMatterCommunication", type = "Unsorted" });
                    }
                }
            }

            return new OkObjectResult(new { match = "", type = "" });
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
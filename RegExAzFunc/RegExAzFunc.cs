using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using System.Text.Json;
namespace Company.Function;

public class RegExAzFunc
{
    // Define a class to map the JSON structure
    public class RegexRequest
    {
        public string strData { get; set; }
        public string regEx { get; set; }
    }
    private readonly ILogger<RegExAzFunc> _logger;

    public RegExAzFunc(ILogger<RegExAzFunc> logger)
    {
        _logger = logger;
    }

    [Function("RegExAzFunc")]
    public async Task<IActionResult> Run([HttpTrigger(AuthorizationLevel.Anonymous, "get", "post")] HttpRequest req)
    {
        try
        {


            // 1. Read the raw body stream
            string requestBody = await new StreamReader(req.Body).ReadToEndAsync();

            // 2. Deserialize JSON into the RegexRequest object
            var data = JsonSerializer.Deserialize<RegexRequest>(requestBody, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            // Validation
            if (data == null || string.IsNullOrEmpty(data.strData) || string.IsNullOrEmpty(data.regEx))
            {
                return new BadRequestObjectResult("Please provide 'strData' and 'regEx' in the request body.");
            }

            // 3. Perform the match
            Match match = Regex.Match(data.strData, data.regEx);

            return new OkObjectResult(new { match = match.Success ? match.Value : "" });
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
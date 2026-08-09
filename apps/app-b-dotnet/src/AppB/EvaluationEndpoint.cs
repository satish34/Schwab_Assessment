using System.Diagnostics;
using System.Text.Json;

namespace AppB;

public static class EvaluationEndpoint
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web);

    public static async Task<IResult> HandleAsync(
        HttpContext context,
        RiskEvaluator evaluator,
        IFaultSettingsProvider faultSettingsProvider,
        StructuredLogWriter logger)
    {
        var started = Stopwatch.GetTimestamp();
        RiskRequest? request = null;
        Dictionary<string, string[]>? bodyErrors = null;

        if (!context.Request.HasJsonContentType())
        {
            bodyErrors = new Dictionary<string, string[]>(StringComparer.Ordinal)
            {
                ["contentType"] = ["Content-Type must be application/json."],
            };
        }
        else
        {
            try
            {
                request = await JsonSerializer.DeserializeAsync<RiskRequest>(
                    context.Request.Body,
                    SerializerOptions,
                    context.RequestAborted);
            }
            catch (JsonException)
            {
                bodyErrors = new Dictionary<string, string[]>(StringComparer.Ordinal)
                {
                    ["body"] = ["The JSON request body is malformed."],
                };
            }
        }

        var requestContext = RequestContext.Create(context, request?.RequestId);
        var validation = bodyErrors is null
            ? RiskRequestValidator.Validate(request)
            : new ValidationResult(null, new Dictionary<string, string[]>());
        var errors = MergeErrors(bodyErrors, validation.Errors, requestContext.Errors);
        var logType = requestContext.IsDependencyProbe ? "dependency_probe" : "request";

        if (errors.Count > 0 || validation.Request is null)
        {
            logger.WriteRequest(
                "WARNING",
                "risk evaluation rejected",
                logType,
                requestContext,
                StatusCodes.Status400BadRequest,
                ElapsedMilliseconds(started),
                string.Empty,
                "validation_error");

            return Results.ValidationProblem(errors, statusCode: StatusCodes.Status400BadRequest);
        }

        try
        {
            var settings = faultSettingsProvider.Current;
            if (settings.InjectedLatencyMs > 0)
            {
                await Task.Delay(settings.InjectedLatencyMs, context.RequestAborted);
            }

            if (FaultSettingsProvider.ShouldInjectFailure(
                    validation.Request.RequestId,
                    settings.InjectedErrorRate))
            {
                throw new InjectedFaultException();
            }

            var response = evaluator.Evaluate(validation.Request);
            logger.WriteRequest(
                "INFO",
                "risk evaluation completed",
                logType,
                requestContext,
                StatusCodes.Status200OK,
                ElapsedMilliseconds(started),
                response.Decision);

            return Results.Ok(response);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            logger.WriteRequest(
                "WARNING",
                "risk evaluation cancelled",
                logType,
                requestContext,
                499,
                ElapsedMilliseconds(started),
                string.Empty,
                "request_cancelled");
            throw;
        }
        catch (InjectedFaultException exception)
        {
            logger.WriteException(
                "risk evaluation failed",
                logType,
                requestContext.CorrelationId,
                requestContext.TraceId,
                StatusCodes.Status503ServiceUnavailable,
                ElapsedMilliseconds(started),
                string.Empty,
                "injected_fault",
                exception);

            return Results.Problem(
                statusCode: StatusCodes.Status503ServiceUnavailable,
                title: "Risk evaluation unavailable");
        }
        catch (Exception exception)
        {
            logger.WriteException(
                "risk evaluation failed",
                logType,
                requestContext.CorrelationId,
                requestContext.TraceId,
                StatusCodes.Status500InternalServerError,
                ElapsedMilliseconds(started),
                string.Empty,
                "internal_error",
                exception);

            return Results.Problem(
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Risk evaluation failed");
        }
    }

    private static Dictionary<string, string[]> MergeErrors(
        params IReadOnlyDictionary<string, string[]>?[] errorSets)
    {
        var result = new Dictionary<string, string[]>(StringComparer.Ordinal);
        foreach (var errorSet in errorSets)
        {
            if (errorSet is null)
            {
                continue;
            }

            foreach (var pair in errorSet)
            {
                result[pair.Key] = pair.Value;
            }
        }

        return result;
    }

    private static long ElapsedMilliseconds(long started) =>
        (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds;
}

public sealed class InjectedFaultException : Exception
{
    public InjectedFaultException()
        : base("A configured evaluation fault was injected.")
    {
    }
}

using System.Diagnostics;

namespace AppB;

public static class ExchangeRatesEndpoint
{
    public static async Task<IResult> HandleAsync(
        HttpContext context,
        ExchangeRateProvider exchangeRateProvider,
        IFaultSettingsProvider faultSettingsProvider,
        IAppBRequestAuthenticator authenticator,
        StructuredLogWriter logger)
    {
        var started = Stopwatch.GetTimestamp();
        var requestContext = RequestContext.Create(context, null);
        var logType = requestContext.IsDependencyProbe ? "dependency_probe" : "request";
        context.Response.Headers.CacheControl = "no-store";

        var authentication = await authenticator.AuthenticateAsync(
            context.Request,
            context.RequestAborted);
        if (!authentication.Succeeded)
        {
            AppBTracing.SuppressCurrentTrace();
            logger.WriteRequest(
                "WARNING",
                "caller authentication rejected",
                logType,
                requestContext,
                StatusCodes.Status401Unauthorized,
                ElapsedMilliseconds(started),
                "AUTH_REJECTED",
                authentication.ErrorType);

            context.Response.Headers.WWWAuthenticate = "Bearer";
            return Results.StatusCode(StatusCodes.Status401Unauthorized);
        }

        if (requestContext.Errors.Count > 0)
        {
            logger.WriteRequest(
                "WARNING",
                "exchange-rate request rejected",
                logType,
                requestContext,
                StatusCodes.Status400BadRequest,
                ElapsedMilliseconds(started),
                string.Empty,
                "validation_error");

            return Results.ValidationProblem(
                new Dictionary<string, string[]>(requestContext.Errors, StringComparer.Ordinal),
                statusCode: StatusCodes.Status400BadRequest);
        }

        try
        {
            var settings = faultSettingsProvider.Current;
            if (settings.InjectedLatencyMs > 0)
            {
                await Task.Delay(settings.InjectedLatencyMs, context.RequestAborted);
            }

            var sampleKey = string.IsNullOrEmpty(requestContext.CorrelationId)
                ? requestContext.TraceId
                : requestContext.CorrelationId;
            if (FaultSettingsProvider.ShouldInjectFailure(sampleKey, settings.InjectedErrorRate))
            {
                throw new InjectedExchangeRateFaultException();
            }

            var response = exchangeRateProvider.GetRates();
            logger.WriteRequest(
                "INFO",
                "exchange rates returned",
                logType,
                requestContext,
                StatusCodes.Status200OK,
                ElapsedMilliseconds(started),
                "RATES_RETURNED");

            return Results.Ok(response);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            logger.WriteRequest(
                "WARNING",
                "exchange-rate request cancelled",
                logType,
                requestContext,
                499,
                ElapsedMilliseconds(started),
                string.Empty,
                "request_cancelled");
            throw;
        }
        catch (InjectedExchangeRateFaultException exception)
        {
            logger.WriteException(
                "exchange-rate request failed",
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
                title: "Exchange rates unavailable");
        }
        catch (Exception exception)
        {
            logger.WriteException(
                "exchange-rate request failed",
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
                title: "Exchange rates request failed");
        }
    }

    private static long ElapsedMilliseconds(long started) =>
        (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds;
}

public sealed class InjectedExchangeRateFaultException : Exception
{
    public InjectedExchangeRateFaultException()
        : base("A configured exchange-rate fault was injected.")
    {
    }
}

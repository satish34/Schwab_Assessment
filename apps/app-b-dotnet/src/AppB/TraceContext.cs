using System.Diagnostics;
using System.Text.RegularExpressions;

namespace AppB;

public sealed partial record RequestContext(
    string CorrelationId,
    string TraceId,
    bool IsDependencyProbe,
    IReadOnlyDictionary<string, string[]> Errors)
{
    public static RequestContext Create(HttpContext context, string? fallbackCorrelationId)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
        ValidateNoInput(context, errors);
        var correlationId = ResolveCorrelationId(context, fallbackCorrelationId, errors);
        var traceId = ResolveTraceId(context, errors);
        var isProbe = string.Equals(
            context.Request.Headers["x-cell-probe"].FirstOrDefault(),
            "true",
            StringComparison.OrdinalIgnoreCase);

        return new RequestContext(correlationId, traceId, isProbe, errors);
    }

    private static void ValidateNoInput(
        HttpContext context,
        IDictionary<string, string[]> errors)
    {
        if (context.Request.QueryString.HasValue)
        {
            errors["query"] = ["Query input is not allowed."];
        }

        if (context.Request.ContentLength is > 0 ||
            context.Request.Headers.TransferEncoding.Count > 0)
        {
            errors["body"] = ["Request body input is not allowed."];
        }
    }

    private static string ResolveCorrelationId(
        HttpContext context,
        string? fallback,
        IDictionary<string, string[]> errors)
    {
        var suppliedValues = context.Request.Headers["x-correlation-id"];
        if (suppliedValues.Count > 1)
        {
            errors["x-correlation-id"] = ["Only one x-correlation-id header is allowed."];
            return string.Empty;
        }

        var supplied = suppliedValues.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(supplied))
        {
            return Guid.TryParse(fallback, out var fallbackId)
                ? fallbackId.ToString("D")
                : string.Empty;
        }

        if (!Guid.TryParse(supplied, out var correlationId))
        {
            errors["x-correlation-id"] = ["x-correlation-id must be a UUID."];
            return string.Empty;
        }

        return correlationId.ToString("D");
    }

    private static string ResolveTraceId(
        HttpContext context,
        IDictionary<string, string[]> errors)
    {
        var suppliedValues = context.Request.Headers.TraceParent;
        if (suppliedValues.Count > 1)
        {
            errors["traceparent"] = ["Only one traceparent header is allowed."];
            return string.Empty;
        }

        var supplied = suppliedValues.FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(supplied))
        {
            var match = TraceParentPattern().Match(supplied);
            if (!match.Success ||
                supplied.StartsWith("ff-", StringComparison.OrdinalIgnoreCase) ||
                match.Groups[1].Value.All(character => character == '0') ||
                match.Groups[2].Value.All(character => character == '0'))
            {
                errors["traceparent"] = ["traceparent must contain a valid W3C trace context."];
                return string.Empty;
            }

            return match.Groups[1].Value.ToLowerInvariant();
        }

        var current = Activity.Current;
        return current is not null && current.TraceId != default
            ? current.TraceId.ToHexString()
            : ActivityTraceId.CreateRandom().ToHexString();
    }

    [GeneratedRegex(
        "^[0-9a-fA-F]{2}-([0-9a-fA-F]{32})-([0-9a-fA-F]{16})-[0-9a-fA-F]{2}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex TraceParentPattern();
}

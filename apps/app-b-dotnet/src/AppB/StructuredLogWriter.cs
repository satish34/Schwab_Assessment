using System.Text.Json;
using System.Text.Json.Serialization;

namespace AppB;

public sealed class StructuredLogWriter
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private readonly AppIdentity _identity;
    private readonly TextWriter _writer;
    private readonly object _writeLock = new();

    public StructuredLogWriter(AppIdentity identity)
        : this(identity, Console.Out)
    {
    }

    public StructuredLogWriter(AppIdentity identity, TextWriter writer)
    {
        _identity = identity;
        _writer = writer;
    }

    public void WriteSchemaSeed() => Write(new StructuredLogEvent(
        "INFO",
        "application schema initialized",
        "schema_seed",
        AppIdentity.ServiceName,
        _identity.Version,
        _identity.Region,
        _identity.Cluster,
        string.Empty,
        string.Empty,
        string.Empty,
        string.Empty,
        0,
        0,
        0,
        string.Empty,
        string.Empty,
        string.Empty,
        false,
        string.Empty));

    public void WriteLifecycle(string severity, string message) => Write(new StructuredLogEvent(
        severity,
        message,
        "lifecycle",
        AppIdentity.ServiceName,
        _identity.Version,
        _identity.Region,
        _identity.Cluster,
        string.Empty,
        string.Empty,
        string.Empty,
        string.Empty,
        0,
        0,
        0,
        string.Empty,
        string.Empty,
        string.Empty,
        false,
        string.Empty));

    public void WriteRequest(
        string severity,
        string message,
        string logType,
        RequestContext requestContext,
        int statusCode,
        long latencyMs,
        string decision,
        string errorType = "",
        string stackTrace = "") => Write(new StructuredLogEvent(
            severity,
            message,
            logType,
            AppIdentity.ServiceName,
            _identity.Version,
            _identity.Region,
            _identity.Cluster,
            requestContext.CorrelationId,
            requestContext.TraceId,
            "/internal/exchange-rates",
            "GET",
            statusCode,
            latencyMs,
            0,
            decision,
            errorType,
            stackTrace,
            false,
            TraceResourceName(requestContext.TraceId)));

    public void WriteException(
        string message,
        string logType,
        string correlationId,
        string traceId,
        int statusCode,
        long latencyMs,
        string decision,
        string errorType,
        Exception exception) => Write(new StructuredLogEvent(
            "ERROR",
            message,
            logType,
            AppIdentity.ServiceName,
            _identity.Version,
            _identity.Region,
            _identity.Cluster,
            correlationId,
            traceId,
            logType is "request" or "dependency_probe" ? "/internal/exchange-rates" : string.Empty,
            logType is "request" or "dependency_probe" ? "GET" : string.Empty,
            statusCode,
            latencyMs,
            0,
            decision,
            errorType,
            exception.ToString(),
            false,
            TraceResourceName(traceId)));

    private string TraceResourceName(string traceId) =>
        string.IsNullOrEmpty(_identity.ProjectId) || string.IsNullOrEmpty(traceId)
            ? string.Empty
            : $"projects/{_identity.ProjectId}/traces/{traceId}";

    private void Write(StructuredLogEvent entry)
    {
        try
        {
            var json = JsonSerializer.Serialize(entry, SerializerOptions);
            lock (_writeLock)
            {
                _writer.WriteLine(json);
                _writer.Flush();
            }
        }
        catch (Exception)
        {
            // Observability must never fail an exchange-rate request.
        }
    }
}

public sealed record StructuredLogEvent(
    [property: JsonPropertyName("severity")] string Severity,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("log_type")] string LogType,
    [property: JsonPropertyName("service")] string Service,
    [property: JsonPropertyName("service_version")] string ServiceVersion,
    [property: JsonPropertyName("region")] string Region,
    [property: JsonPropertyName("cluster")] string Cluster,
    [property: JsonPropertyName("correlation_id")] string CorrelationId,
    [property: JsonPropertyName("trace_id")] string TraceId,
    [property: JsonPropertyName("route")] string Route,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("status_code")] int StatusCode,
    [property: JsonPropertyName("latency_ms")] long LatencyMs,
    [property: JsonPropertyName("downstream_latency_ms")] long DownstreamLatencyMs,
    [property: JsonPropertyName("decision")] string Decision,
    [property: JsonPropertyName("error_type")] string ErrorType,
    [property: JsonPropertyName("stack_trace")] string StackTrace,
    [property: JsonPropertyName("is_test")] bool IsTest,
    [property: JsonPropertyName("logging.googleapis.com/trace")] string GoogleTrace);

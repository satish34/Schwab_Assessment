using System.Text.Json;
using AppB;

namespace AppB.Tests;

public sealed class StructuredLogWriterTests
{
    [Fact]
    public void SchemaSeedContainsEveryStableFieldWithExpectedTypes()
    {
        using var output = new StringWriter();
        var logger = new StructuredLogWriter(
            new AppIdentity("us-central1", "gke-risk-usc1", "abc123", "test-project"),
            output);

        logger.WriteSchemaSeed();

        using var document = JsonDocument.Parse(output.ToString());
        var root = document.RootElement;

        Assert.Equal("schema_seed", root.GetProperty("log_type").GetString());
        Assert.Equal("app-b-engine", root.GetProperty("service").GetString());
        Assert.Equal(JsonValueKind.Number, root.GetProperty("status_code").ValueKind);
        Assert.Equal(JsonValueKind.Number, root.GetProperty("latency_ms").ValueKind);
        Assert.Equal(JsonValueKind.Number, root.GetProperty("downstream_latency_ms").ValueKind);
        Assert.Equal(JsonValueKind.String, root.GetProperty("stack_trace").ValueKind);
        Assert.Equal(JsonValueKind.False, root.GetProperty("is_test").ValueKind);
        Assert.Equal(JsonValueKind.String, root.GetProperty("logging.googleapis.com/trace").ValueKind);
        Assert.Equal(19, root.EnumerateObject().Count());
    }

    [Fact]
    public void RequestLogPreservesJoinIdentifiersAndGoogleTraceResource()
    {
        using var output = new StringWriter();
        var logger = new StructuredLogWriter(
            new AppIdentity("us-central1", "gke-risk-usc1", "abc123", "test-project"),
            output);
        var context = new RequestContext(
            "550e8400-e29b-41d4-a716-446655440000",
            "0123456789abcdef0123456789abcdef",
            false,
            new Dictionary<string, string[]>());

        logger.WriteRequest("INFO", "risk evaluation completed", "request", context, 200, 42, "REVIEW");

        using var document = JsonDocument.Parse(output.ToString());
        var root = document.RootElement;
        Assert.Equal(context.CorrelationId, root.GetProperty("correlation_id").GetString());
        Assert.Equal(context.TraceId, root.GetProperty("trace_id").GetString());
        Assert.Equal(
            $"projects/test-project/traces/{context.TraceId}",
            root.GetProperty("logging.googleapis.com/trace").GetString());
        Assert.Equal(42, root.GetProperty("latency_ms").GetInt64());
        Assert.Equal(200, root.GetProperty("status_code").GetInt32());
    }

    [Fact]
    public void ErrorLogIsOneJsonLineWithEveryFrozenFieldAndDotNetStackTrace()
    {
        using var output = new StringWriter();
        var logger = new StructuredLogWriter(
            new AppIdentity("us-central1", "gke-risk-usc1", "abc123", "test-project"),
            output);

        logger.WriteException(
            "risk evaluation failed",
            "request",
            "550e8400-e29b-41d4-a716-446655440000",
            "0123456789abcdef0123456789abcdef",
            503,
            17,
            string.Empty,
            "controlled_test_error",
            CaptureException());

        var lines = output.ToString().Split(
            ["\r\n", "\n"],
            StringSplitOptions.RemoveEmptyEntries);
        var line = Assert.Single(lines);
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var expectedFields = new[]
        {
            "severity",
            "message",
            "log_type",
            "service",
            "service_version",
            "region",
            "cluster",
            "correlation_id",
            "trace_id",
            "route",
            "method",
            "status_code",
            "latency_ms",
            "downstream_latency_ms",
            "decision",
            "error_type",
            "stack_trace",
            "is_test",
            "logging.googleapis.com/trace",
        };

        Assert.Equal(expectedFields, root.EnumerateObject().Select(property => property.Name));
        Assert.Equal(19, root.EnumerateObject().Count());
        Assert.Equal("ERROR", root.GetProperty("severity").GetString());
        var stackTrace = root.GetProperty("stack_trace").GetString();
        Assert.False(string.IsNullOrWhiteSpace(stackTrace));
        Assert.Contains("System.InvalidOperationException: controlled test failure", stackTrace);
        Assert.Contains(" at AppB.Tests.StructuredLogWriterTests.CaptureException()", stackTrace);
    }

    private static Exception CaptureException()
    {
        try
        {
            throw new InvalidOperationException("controlled test failure");
        }
        catch (InvalidOperationException exception)
        {
            return exception;
        }
    }
}

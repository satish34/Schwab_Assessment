using System.Diagnostics;
using System.Net;
using AppB;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry;

namespace AppB.Tests;

public sealed class AppBTracingTests
{
    [Fact]
    public void ExportIsDisabledByDefaultForLocalAndTestRuns()
    {
        var settings = AppBTracingSettings.FromConfiguration(
            new ConfigurationBuilder().Build());

        Assert.False(settings.Enabled);
        Assert.Null(settings.OtlpEndpoint);
    }

    [Fact]
    public void RootTraceSamplingIsBoundedToTenPercent()
    {
        Assert.Equal(0.1, AppBTracing.RootSampleRatio);
    }

    [Fact]
    public void OtlpModeRequiresAndPreservesTheTelemetryApiEndpoint()
    {
        var settings = AppBTracingSettings.FromConfiguration(CreateConfiguration(
            ("OTEL_TRACES_EXPORTER", "otlp"),
            ("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf"),
            (
                "OTEL_EXPORTER_OTLP_ENDPOINT",
                AppBTracingSettings.TelemetryApiTraceEndpoint)));

        Assert.True(settings.Enabled);
        Assert.Equal(
            new Uri(
                AppBTracingSettings.TelemetryApiTraceEndpoint),
            settings.OtlpEndpoint);
    }

    [Theory]
    [InlineData("zipkin", AppBTracingSettings.TelemetryApiTraceEndpoint, null)]
    [InlineData("otlp", null, null)]
    [InlineData("otlp", "https://example.com/v1/traces", "http/protobuf")]
    [InlineData("otlp", AppBTracingSettings.TelemetryApiTraceEndpoint, "grpc")]
    public void InvalidExporterConfigurationFailsAtStartup(
        string exporter,
        string? endpoint,
        string? protocol)
    {
        var configuration = CreateConfiguration(
            ("OTEL_TRACES_EXPORTER", exporter),
            ("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint),
            ("OTEL_EXPORTER_OTLP_PROTOCOL", protocol));

        var exception = Assert.Throws<InvalidOperationException>(
            () => AppBTracingSettings.FromConfiguration(configuration));

        Assert.Contains("OTEL_", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExportRequestsUseARefreshableBearerTokenWithoutChangingTheBody()
    {
        var tokenProvider = new StubAccessTokenProvider("workload-identity-access-token");
        var destination = new CapturingHttpMessageHandler();
        using var handler = new GoogleAccessTokenHandler(tokenProvider)
        {
            InnerHandler = destination,
        };
        using var client = new HttpClient(handler);
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            AppBTracingSettings.TelemetryApiTraceEndpoint)
        {
            Content = new ByteArrayContent([1, 2, 3]),
        };

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(1, tokenProvider.CallCount);
        Assert.Equal(
            new Uri(AppBTracingSettings.TelemetryApiTraceEndpoint),
            tokenProvider.LastRequestUri);
        Assert.Equal("Bearer", destination.AuthorizationScheme);
        Assert.Equal("workload-identity-access-token", destination.AuthorizationParameter);
        Assert.Equal([1, 2, 3], destination.Body);
    }

    [Fact]
    public void W3cIdentifiersAreForcedBeforeRequestInstrumentationStarts()
    {
        var services = new ServiceCollection();
        services.AddAppBTracing(
            CreateConfiguration(("OTEL_TRACES_EXPORTER", "none")),
            new AppIdentity("us-central1", "cluster", "version", "project"));

        Assert.Equal(ActivityIdFormat.W3C, Activity.DefaultIdFormat);
        Assert.True(Activity.ForceDefaultIdFormat);
    }

    [Fact]
    public void DependencyProbesAreExcludedFromTraceExport()
    {
        var context = new DefaultHttpContext();
        context.Request.Path = "/internal/exchange-rates";
        context.Request.Headers["x-cell-probe"] = "true";

        Assert.False(AppBTracing.ShouldTraceRequest(context));

        context.Request.Headers.Remove("x-cell-probe");
        Assert.True(AppBTracing.ShouldTraceRequest(context));
    }

    [Fact]
    public void AuthenticationRejectionClearsTheRecordedFlag()
    {
        using var activity = new Activity("test-request");
        activity.ActivityTraceFlags = ActivityTraceFlags.Recorded;
        activity.IsAllDataRequested = true;
        activity.Start();

        AppBTracing.SuppressCurrentTrace();

        Assert.False(activity.Recorded);
        Assert.True(activity.IsAllDataRequested);
    }

    [Fact]
    public void ExportedServerSpanCarriesExactReviewerVisibleIdentity()
    {
        using var activity = new Activity("request");
        var identity = new AppIdentity(
            "us-central1",
            "gke-risk-usc1",
            "0123456789abcdef0123456789abcdef01234567",
            "test-project");
        activity.Start();

        AppBTracing.AddAssessmentIdentity(activity, identity);

        Assert.Equal("app-b-engine", activity.GetTagItem("assessment.service.name"));
        Assert.Equal(identity.Version, activity.GetTagItem("assessment.service.version"));
        Assert.Equal(identity.Region, activity.GetTagItem("assessment.cloud.region"));
        Assert.Equal(identity.Cluster, activity.GetTagItem("assessment.k8s.cluster.name"));
    }

    [Fact]
    public void SuppressedAuthenticationRejectionIsNotQueuedForExport()
    {
        var exporter = new CountingActivityExporter();
        using var processor = new BatchActivityExportProcessor(
            exporter,
            scheduledDelayMilliseconds: 1,
            exporterTimeoutMilliseconds: 100,
            maxExportBatchSize: 1);
        using var activity = new Activity("rejected-request");
        activity.ActivityTraceFlags = ActivityTraceFlags.Recorded;
        activity.Start();

        AppBTracing.SuppressCurrentTrace();
        processor.OnEnd(activity);
        processor.ForceFlush(1_000);

        Assert.Equal(0, exporter.ExportedCount);
    }

    private static IConfiguration CreateConfiguration(
        params (string Key, string? Value)[] values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values.ToDictionary(value => value.Key, value => value.Value))
            .Build();

    private sealed class StubAccessTokenProvider(string token) : IGoogleAccessTokenProvider
    {
        public int CallCount { get; private set; }

        public Uri? LastRequestUri { get; private set; }

        public Task<string> GetAccessTokenAsync(
            Uri requestUri,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            LastRequestUri = requestUri;
            return Task.FromResult(token);
        }
    }

    private sealed class CapturingHttpMessageHandler : HttpMessageHandler
    {
        public string? AuthorizationScheme { get; private set; }

        public string? AuthorizationParameter { get; private set; }

        public byte[]? Body { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            AuthorizationScheme = request.Headers.Authorization?.Scheme;
            AuthorizationParameter = request.Headers.Authorization?.Parameter;
            Body = request.Content is null
                ? null
                : await request.Content.ReadAsByteArrayAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }

    private sealed class CountingActivityExporter : BaseExporter<Activity>
    {
        public long ExportedCount { get; private set; }

        public override ExportResult Export(in Batch<Activity> batch)
        {
            ExportedCount += batch.Count;
            return ExportResult.Success;
        }
    }
}

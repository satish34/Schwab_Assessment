using System.Diagnostics;
using System.Net.Http.Headers;
using Google.Apis.Auth.OAuth2;
using OpenTelemetry.Exporter;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace AppB;

public sealed record AppBTracingSettings(bool Enabled, Uri? OtlpEndpoint)
{
    public const string DisabledExporterName = "none";
    public const string OtlpExporterName = "otlp";
    public const string HttpProtobufProtocolName = "http/protobuf";
    public const string TelemetryApiTraceEndpoint =
        "https://telemetry.googleapis.com/v1/traces";

    public static AppBTracingSettings FromConfiguration(IConfiguration configuration)
    {
        var exporter = configuration["OTEL_TRACES_EXPORTER"]?.Trim();
        if (string.IsNullOrEmpty(exporter) ||
            string.Equals(exporter, DisabledExporterName, StringComparison.OrdinalIgnoreCase))
        {
            return new AppBTracingSettings(false, null);
        }

        if (!string.Equals(exporter, OtlpExporterName, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "OTEL_TRACES_EXPORTER must be 'none' or 'otlp'.");
        }

        var configuredProtocol = configuration["OTEL_EXPORTER_OTLP_PROTOCOL"]?.Trim();
        if (!string.Equals(
                configuredProtocol,
                HttpProtobufProtocolName,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "Direct App B tracing supports only OTLP/HTTP; " +
                "OTEL_EXPORTER_OTLP_PROTOCOL must be 'http/protobuf'.");
        }

        var configuredEndpoint = configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]?.Trim();
        if (!Uri.TryCreate(configuredEndpoint, UriKind.Absolute, out var endpoint) ||
            !string.Equals(
                endpoint.AbsoluteUri.TrimEnd('/'),
                TelemetryApiTraceEndpoint,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "OTEL_EXPORTER_OTLP_ENDPOINT must be the Google Telemetry API trace " +
                $"endpoint '{TelemetryApiTraceEndpoint}' when OTEL_TRACES_EXPORTER is 'otlp'.");
        }

        return new AppBTracingSettings(true, endpoint);
    }
}

public static class AppBTracing
{
    private const string ExchangeRatesPath = "/internal/exchange-rates";
    public const double RootSampleRatio = 0.1;

    public static bool ShouldTraceRequest(HttpContext context) =>
        context.Request.Path == ExchangeRatesPath &&
        !string.Equals(
            context.Request.Headers["x-cell-probe"].FirstOrDefault(),
            "true",
            StringComparison.OrdinalIgnoreCase);

    public static void SuppressCurrentTrace()
    {
        var activity = Activity.Current;
        if (activity is not null)
        {
            activity.ActivityTraceFlags &= ~ActivityTraceFlags.Recorded;
        }
    }

    public static void AddAssessmentIdentity(Activity activity, AppIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        ArgumentNullException.ThrowIfNull(identity);
        activity.SetTag("assessment.service.name", AppIdentity.ServiceName);
        activity.SetTag("assessment.service.version", identity.Version);
        activity.SetTag("assessment.cloud.region", identity.Region);
        activity.SetTag("assessment.k8s.cluster.name", identity.Cluster);
    }

    public static IServiceCollection AddAppBTracing(
        this IServiceCollection services,
        IConfiguration configuration,
        AppIdentity identity)
    {
        Activity.DefaultIdFormat = ActivityIdFormat.W3C;
        Activity.ForceDefaultIdFormat = true;

        var settings = AppBTracingSettings.FromConfiguration(configuration);
        services.AddSingleton(settings);
        if (!settings.Enabled)
        {
            return services;
        }

        if (string.IsNullOrWhiteSpace(identity.ProjectId))
        {
            throw new InvalidOperationException(
                "GOOGLE_CLOUD_PROJECT is required when direct trace export is enabled.");
        }

        var accessTokenProvider = new GoogleApplicationDefaultAccessTokenProvider();
        services.AddSingleton<IGoogleAccessTokenProvider>(accessTokenProvider);

        services
            .AddOpenTelemetry()
            .ConfigureResource(resource => resource
                .AddService(
                    AppIdentity.ServiceName,
                    serviceVersion: identity.Version)
                .AddAttributes(
                [
                    new KeyValuePair<string, object>("cloud.region", identity.Region),
                    new KeyValuePair<string, object>("gcp.project_id", identity.ProjectId),
                    new KeyValuePair<string, object>("k8s.cluster.name", identity.Cluster),
                ]))
            .WithTracing(tracing => tracing
                .SetSampler(new ParentBasedSampler(
                    new TraceIdRatioBasedSampler(RootSampleRatio)))
                .AddAspNetCoreInstrumentation(options =>
                {
                    options.Filter = ShouldTraceRequest;
                    options.RecordException = true;
                    options.EnrichWithHttpRequest = (activity, _) =>
                        AddAssessmentIdentity(activity, identity);
                })
                .AddOtlpExporter(options =>
                {
                    options.Endpoint = settings.OtlpEndpoint!;
                    options.Protocol = OtlpExportProtocol.HttpProtobuf;
                    options.TimeoutMilliseconds = 2_000;
                    options.HttpClientFactory = () => new HttpClient(
                        new GoogleAccessTokenHandler(accessTokenProvider)
                        {
                            InnerHandler = new SocketsHttpHandler(),
                        },
                        disposeHandler: true);
                }));

        return services;
    }
}

public interface IGoogleAccessTokenProvider
{
    Task<string> GetAccessTokenAsync(Uri requestUri, CancellationToken cancellationToken);
}

public sealed class GoogleApplicationDefaultAccessTokenProvider : IGoogleAccessTokenProvider
{
    private const string CloudPlatformScope =
        "https://www.googleapis.com/auth/cloud-platform";

    private readonly Lazy<Task<GoogleCredential>> _credential = new(
        CreateCredentialAsync,
        LazyThreadSafetyMode.ExecutionAndPublication);

    public async Task<string> GetAccessTokenAsync(
        Uri requestUri,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(requestUri);
        var credential = await _credential.Value.WaitAsync(cancellationToken);
        return await ((ITokenAccess)credential).GetAccessTokenForRequestAsync(
            requestUri.AbsoluteUri,
            cancellationToken);
    }

    private static async Task<GoogleCredential> CreateCredentialAsync()
    {
        var credential = await GoogleCredential.GetApplicationDefaultAsync();
        return credential.IsCreateScopedRequired
            ? credential.CreateScoped(CloudPlatformScope)
            : credential;
    }
}

public sealed class GoogleAccessTokenHandler(
    IGoogleAccessTokenProvider tokenProvider) : DelegatingHandler
{
    protected override HttpResponseMessage Send(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        var requestUri = RequireRequestUri(request);
        var accessToken = tokenProvider.GetAccessTokenAsync(
            requestUri,
            cancellationToken).ConfigureAwait(false).GetAwaiter().GetResult();
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        return base.Send(request, cancellationToken);
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        var requestUri = RequireRequestUri(request);
        var accessToken = await tokenProvider.GetAccessTokenAsync(
            requestUri,
            cancellationToken);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        return await base.SendAsync(request, cancellationToken);
    }

    private static Uri RequireRequestUri(HttpRequestMessage request) =>
        request.RequestUri ?? throw new InvalidOperationException(
            "The OTLP export request must have a destination URI.");
}

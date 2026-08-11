using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace AppB.Tests;

public sealed class AppBApiTests
{
    private const string ExchangeRatesPath = "/internal/exchange-rates";

    [Fact]
    public async Task GetReturnsExactExchangeRateContractAndIdentity()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = CreateRequest();

        using var response = await client.SendAsync(request);
        var json = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("no-store", response.Headers.CacheControl?.ToString());
        Assert.Equal(
            "{\"baseCurrency\":\"USD\",\"rateSnapshots\":[" +
            "{\"EUR\":0.92,\"GBP\":0.78,\"JPY\":149.50}," +
            "{\"EUR\":0.93,\"GBP\":0.79,\"JPY\":150.10}," +
            "{\"EUR\":0.91,\"GBP\":0.77,\"JPY\":148.90}," +
            "{\"EUR\":0.92,\"GBP\":0.79,\"JPY\":149.80}," +
            "{\"EUR\":0.93,\"GBP\":0.78,\"JPY\":149.20}," +
            "{\"EUR\":0.91,\"GBP\":0.78,\"JPY\":150.00}," +
            "{\"EUR\":0.92,\"GBP\":0.77,\"JPY\":149.10}," +
            "{\"EUR\":0.93,\"GBP\":0.77,\"JPY\":149.70}," +
            "{\"EUR\":0.91,\"GBP\":0.79,\"JPY\":149.40}," +
            "{\"EUR\":0.92,\"GBP\":0.78,\"JPY\":149.90}]," +
            "\"disclaimer\":\"Synthetic demonstration rates - not for financial use.\"," +
            "\"providedBy\":{\"service\":\"app-b-engine\",\"region\":\"us-central1\"," +
            "\"cluster\":\"gke-currency-usc1\",\"version\":\"test-sha\"}}",
            json);
    }

    [Fact]
    public async Task ResponseHasOnlyTheFrozenTopLevelFields()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();

        using var response = await client.GetAsync(ExchangeRatesPath);
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        Assert.Equal(
            ["baseCurrency", "rateSnapshots", "disclaimer", "providedBy"],
            body.RootElement.EnumerateObject().Select(property => property.Name));
        var snapshots = body.RootElement.GetProperty("rateSnapshots").EnumerateArray().ToArray();
        Assert.Equal(10, snapshots.Length);
        Assert.All(
            snapshots,
            snapshot => Assert.Equal(
                ["EUR", "GBP", "JPY"],
                snapshot.EnumerateObject().Select(property => property.Name)));
        Assert.Equal(
            ["service", "region", "cluster", "version"],
            body.RootElement.GetProperty("providedBy").EnumerateObject().Select(property => property.Name));
    }

    [Fact]
    public async Task RepeatedGetsReturnTheSameStatelessCatalog()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();

        using var first = await client.GetAsync(ExchangeRatesPath);
        using var second = await client.GetAsync(ExchangeRatesPath);

        Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        Assert.Equal(HttpStatusCode.OK, second.StatusCode);
        Assert.Equal(
            await first.Content.ReadAsStringAsync(),
            await second.Content.ReadAsStringAsync());
    }

    [Theory]
    [InlineData("/health/live")]
    [InlineData("/health/ready")]
    public async Task HealthEndpointsAreAvailable(string path)
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();

        using var response = await client.GetAsync(path);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Theory]
    [InlineData("/health/live")]
    [InlineData("/health/ready")]
    public async Task HealthEndpointsRemainUnauthenticatedWhenCallerAuthIsEnabled(string path)
    {
        var verifier = new StubGoogleIdTokenVerifier(
            GoogleIdTokenVerificationResult.Valid(CreateValidTokenClaims()));
        await using var factory = new AppBFactory(
            authMode: AppBAuthenticationSettings.GoogleIdTokenModeName,
            tokenVerifier: verifier);
        using var client = factory.CreateClient();

        using var response = await client.GetAsync(path);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(0, verifier.CallCount);
    }

    [Fact]
    public async Task ValidGoogleCallerTokenPreservesTheSuccessContract()
    {
        var verifier = new StubGoogleIdTokenVerifier(
            GoogleIdTokenVerificationResult.Valid(CreateValidTokenClaims()));
        await using var factory = new AppBFactory(
            authMode: AppBAuthenticationSettings.GoogleIdTokenModeName,
            tokenVerifier: verifier);
        using var client = factory.CreateClient();
        using var request = CreateRequest();
        request.Headers.TryAddWithoutValidation(
            "Authorization",
            "Bearer header.payload.signature");

        using var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("\"rateSnapshots\"", body, StringComparison.Ordinal);
        Assert.Equal(1, verifier.CallCount);
        Assert.Equal("header.payload.signature", verifier.LastToken);
        Assert.Equal(AppBAuthenticationSettings.DefaultAudience, verifier.LastAudience);
    }

    [Fact]
    public async Task MissingCallerTokenReturnsDeterministic401AndFrozenAuthLog()
    {
        var verifier = new StubGoogleIdTokenVerifier(
            GoogleIdTokenVerificationResult.Valid(CreateValidTokenClaims()));
        await using var factory = new AppBFactory(
            authMode: AppBAuthenticationSettings.GoogleIdTokenModeName,
            tokenVerifier: verifier);
        using var client = factory.CreateClient();
        using var request = CreateRequest();

        using var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Equal("no-store", response.Headers.CacheControl?.ToString());
        Assert.Equal("Bearer", Assert.Single(response.Headers.WwwAuthenticate).Scheme);
        Assert.Equal(string.Empty, body);
        Assert.Equal(0, verifier.CallCount);

        var entries = factory.LogOutput.ToString().Split(
            ["\r\n", "\n"],
            StringSplitOptions.RemoveEmptyEntries);
        var rejectionLine = Assert.Single(entries, entry =>
        {
            using var document = JsonDocument.Parse(entry);
            return document.RootElement.GetProperty("decision").GetString() == "AUTH_REJECTED";
        });
        using var rejectionDocument = JsonDocument.Parse(rejectionLine);
        var rejection = rejectionDocument.RootElement;
        Assert.Equal(19, rejection.EnumerateObject().Count());
        Assert.Equal(401, rejection.GetProperty("status_code").GetInt32());
        Assert.Equal("authorization_missing", rejection.GetProperty("error_type").GetString());
        Assert.Equal("/internal/exchange-rates", rejection.GetProperty("route").GetString());
        Assert.Equal("GET", rejection.GetProperty("method").GetString());
    }

    [Fact]
    public async Task InvalidSignedTokenIsRejectedWithoutWritingTheToken()
    {
        const string token = "secret.header.signature";
        var verifier = new StubGoogleIdTokenVerifier(
            GoogleIdTokenVerificationResult.InvalidToken);
        await using var factory = new AppBFactory(
            authMode: AppBAuthenticationSettings.GoogleIdTokenModeName,
            tokenVerifier: verifier);
        using var client = factory.CreateClient();
        using var request = CreateRequest();
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Equal(1, verifier.CallCount);
        Assert.DoesNotContain(token, factory.LogOutput.ToString(), StringComparison.Ordinal);
        Assert.Contains("\"decision\":\"AUTH_REJECTED\"", factory.LogOutput.ToString());
        Assert.Contains("\"error_type\":\"token_validation_failed\"", factory.LogOutput.ToString());
    }

    [Fact]
    public async Task VerifierOutageReturnsTheSameEmpty401WithoutWritingTheToken()
    {
        const string token = "secret.verifier.outage";
        var verifier = new StubGoogleIdTokenVerifier(
            GoogleIdTokenVerificationResult.VerifierUnavailable);
        await using var factory = new AppBFactory(
            authMode: AppBAuthenticationSettings.GoogleIdTokenModeName,
            tokenVerifier: verifier);
        using var client = factory.CreateClient();
        using var request = CreateRequest();
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");

        using var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Equal("no-store", response.Headers.CacheControl?.ToString());
        Assert.Equal(string.Empty, body);
        Assert.Equal(1, verifier.CallCount);
        Assert.DoesNotContain(token, factory.LogOutput.ToString(), StringComparison.Ordinal);
        Assert.Contains(
            "\"error_type\":\"token_verifier_unavailable\"",
            factory.LogOutput.ToString(),
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task PostIsNotAllowedOnTheGetOnlyEndpoint()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();

        using var response = await client.PostAsync(ExchangeRatesPath, null);

        Assert.Equal(HttpStatusCode.MethodNotAllowed, response.StatusCode);
    }

    [Fact]
    public async Task QueryInputIsRejectedWithoutReturningRates()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();

        using var response = await client.GetAsync($"{ExchangeRatesPath}?base=EUR");
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("no-store", response.Headers.CacheControl?.ToString());
        Assert.Contains("Query input is not allowed.", body, StringComparison.Ordinal);
        Assert.DoesNotContain("rateSnapshots", body, StringComparison.Ordinal);
        var entries = factory.LogOutput.ToString().Split(
            ["\r\n", "\n"],
            StringSplitOptions.RemoveEmptyEntries);
        var rejectionLine = Assert.Single(entries, entry =>
        {
            using var document = JsonDocument.Parse(entry);
            return document.RootElement.GetProperty("log_type").GetString() == "request";
        });
        using var rejectionDocument = JsonDocument.Parse(rejectionLine);
        var rejection = rejectionDocument.RootElement;
        Assert.Equal(400, rejection.GetProperty("status_code").GetInt32());
        Assert.Equal("validation_error", rejection.GetProperty("error_type").GetString());
        Assert.Equal(string.Empty, rejection.GetProperty("decision").GetString());
    }

    [Fact]
    public async Task FixedLengthGetBodyIsRejectedWithoutReturningRates()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, ExchangeRatesPath)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json"),
        };
        Assert.Equal(2, request.Content.Headers.ContentLength);

        using var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("Request body input is not allowed.", body, StringComparison.Ordinal);
        Assert.DoesNotContain("rateSnapshots", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ChunkedGetBodyWithoutContentLengthIsRejectedWithoutReturningRates()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, ExchangeRatesPath)
        {
            Content = new UnknownLengthContent("{}"),
        };
        request.Headers.TransferEncodingChunked = true;
        Assert.Null(request.Content.Headers.ContentLength);

        using var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("Request body input is not allowed.", body, StringComparison.Ordinal);
        Assert.DoesNotContain("rateSnapshots", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CellProbeUsesTheDependencyProbeLogContract()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = CreateRequest();
        request.Headers.Add("x-cell-probe", "true");

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var entries = factory.LogOutput.ToString().Split(
            ["\r\n", "\n"],
            StringSplitOptions.RemoveEmptyEntries);
        var probeLine = Assert.Single(entries, entry =>
        {
            using var document = JsonDocument.Parse(entry);
            return document.RootElement.GetProperty("log_type").GetString() == "dependency_probe";
        });
        using var probeDocument = JsonDocument.Parse(probeLine);
        var probe = probeDocument.RootElement;
        Assert.Equal("/internal/exchange-rates", probe.GetProperty("route").GetString());
        Assert.Equal("GET", probe.GetProperty("method").GetString());
        Assert.Equal("RATES_RETURNED", probe.GetProperty("decision").GetString());
        Assert.Equal(19, probe.EnumerateObject().Count());
    }

    [Fact]
    public async Task InvalidTraceParentReturns400()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = CreateRequest();
        request.Headers.Remove("traceparent");
        request.Headers.TryAddWithoutValidation("traceparent", "invalid");

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("no-store", response.Headers.CacheControl?.ToString());
    }

    [Fact]
    public async Task InvalidCorrelationIdReturns400()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = CreateRequest();
        request.Headers.Remove("x-correlation-id");
        request.Headers.TryAddWithoutValidation("x-correlation-id", "invalid");

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task InjectedFailureReturnsGeneric503WithoutExceptionText()
    {
        var path = Path.Combine(Path.GetTempPath(), $"app-b-fault-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(
            path,
            """{"injected_latency_ms":0,"injected_error_rate":1.0}""");

        try
        {
            await using var factory = new AppBFactory(path);
            using var client = factory.CreateClient();
            using var request = CreateRequest();

            using var response = await client.SendAsync(request);
            var body = await response.Content.ReadAsStringAsync();

            Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
            Assert.Contains("Exchange rates unavailable", body, StringComparison.Ordinal);
            Assert.DoesNotContain("configured exchange-rate fault", body, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(
                nameof(InjectedExchangeRateFaultException),
                body,
                StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task InjectedLatencyIsAppliedBeforeAResponse()
    {
        var path = Path.Combine(Path.GetTempPath(), $"app-b-latency-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(
            path,
            """{"injected_latency_ms":75,"injected_error_rate":0.0}""");

        try
        {
            await using var factory = new AppBFactory(path);
            using var client = factory.CreateClient();
            using var request = CreateRequest();
            var started = Stopwatch.GetTimestamp();

            using var response = await client.SendAsync(request);
            var elapsed = Stopwatch.GetElapsedTime(started);

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.True(elapsed >= TimeSpan.FromMilliseconds(60), $"Elapsed only {elapsed.TotalMilliseconds} ms.");
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static HttpRequestMessage CreateRequest()
    {
        var request = new HttpRequestMessage(HttpMethod.Get, ExchangeRatesPath);
        request.Headers.Add("x-correlation-id", "550e8400-e29b-41d4-a716-446655440000");
        request.Headers.Add(
            "traceparent",
            "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01");
        return request;
    }

    private sealed class UnknownLengthContent(string value) : HttpContent
    {
        private readonly byte[] _content = Encoding.UTF8.GetBytes(value);

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            stream.WriteAsync(_content).AsTask();

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }

    private static GoogleIdTokenClaims CreateValidTokenClaims()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        return new GoogleIdTokenClaims(
            "https://accounts.google.com",
            [AppBAuthenticationSettings.DefaultAudience],
            now - 60,
            now + 3600,
            now - 60,
            "currency-app-a-caller@test-project.iam.gserviceaccount.com",
            true);
    }

    private sealed class AppBFactory(
        string? faultPath = null,
        string authMode = AppBAuthenticationSettings.DisabledModeName,
        IGoogleIdTokenVerifier? tokenVerifier = null) : WebApplicationFactory<Program>
    {
        public StringWriter LogOutput { get; } = new();

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Testing");
            builder.ConfigureAppConfiguration((_, configuration) =>
            {
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["SERVICE_REGION"] = "us-central1",
                    ["SERVICE_CLUSTER"] = "gke-currency-usc1",
                    ["SERVICE_VERSION"] = "test-sha",
                    ["GOOGLE_CLOUD_PROJECT"] = "test-project",
                    ["APP_B_AUTH_MODE"] = authMode,
                    ["APP_B_TOKEN_AUDIENCE"] = AppBAuthenticationSettings.DefaultAudience,
                    ["APP_A_IDENTITY_EMAIL"] =
                        "currency-app-a-caller@test-project.iam.gserviceaccount.com",
                    ["FAULT_CONFIG_PATH"] = faultPath ?? Path.Combine(
                        Path.GetTempPath(),
                        $"missing-app-b-fault-{Guid.NewGuid():N}.json"),
                });
            });
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<StructuredLogWriter>();
                services.AddSingleton(new StructuredLogWriter(
                    new AppIdentity(
                        "us-central1",
                        "gke-currency-usc1",
                        "test-sha",
                        "test-project"),
                    LogOutput));
                if (tokenVerifier is not null)
                {
                    services.RemoveAll<IGoogleIdTokenVerifier>();
                    services.AddSingleton(tokenVerifier);
                }
            });
        }
    }

    private sealed class StubGoogleIdTokenVerifier(
        GoogleIdTokenVerificationResult result) : IGoogleIdTokenVerifier
    {
        public int CallCount { get; private set; }

        public string? LastToken { get; private set; }

        public string? LastAudience { get; private set; }

        public Task<GoogleIdTokenVerificationResult> VerifyAsync(
            string token,
            string audience,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            LastToken = token;
            LastAudience = audience;
            return Task.FromResult(result);
        }
    }
}

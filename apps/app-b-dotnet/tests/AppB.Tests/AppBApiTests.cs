using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace AppB.Tests;

public sealed class AppBApiTests
{
    private const string ContractRequest = """
        {
          "requestId": "550e8400-e29b-41d4-a716-446655440000",
          "amount": 1250.50,
          "currency": "USD",
          "merchantCategory": "ELECTRONICS",
          "countryCode": "US",
          "channel": "CARD_NOT_PRESENT"
        }
        """;

    [Fact]
    public async Task ExactContractRequestReturnsExactResponseShapeAndIdentity()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = CreateRequest(ContractRequest);

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = body.RootElement;
        Assert.Equal("550e8400-e29b-41d4-a716-446655440000", root.GetProperty("requestId").GetString());
        Assert.Equal(48, root.GetProperty("score").GetInt32());
        Assert.Equal("REVIEW", root.GetProperty("decision").GetString());
        Assert.Equal(
            ["CARD_NOT_PRESENT", "AMOUNT_OVER_1000"],
            root.GetProperty("rulesFired").EnumerateArray().Select(item => item.GetString()));
        Assert.Equal("app-b-engine", root.GetProperty("evaluatedBy").GetProperty("service").GetString());
        Assert.Equal("us-central1", root.GetProperty("evaluatedBy").GetProperty("region").GetString());
        Assert.Equal("gke-risk-usc1", root.GetProperty("evaluatedBy").GetProperty("cluster").GetString());
        Assert.Equal("test-sha", root.GetProperty("evaluatedBy").GetProperty("version").GetString());
        Assert.Equal(
            ["requestId", "score", "decision", "rulesFired", "evaluatedBy"],
            root.EnumerateObject().Select(property => property.Name));
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

    [Fact]
    public async Task InvalidRequestReturns400()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();

        using var response = await client.PostAsJsonAsync("/v1/evaluate", new { amount = -1 });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task InvalidTraceParentReturns400()
    {
        await using var factory = new AppBFactory();
        using var client = factory.CreateClient();
        using var request = CreateRequest(ContractRequest);
        request.Headers.Remove("traceparent");
        request.Headers.TryAddWithoutValidation("traceparent", "invalid");

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
            using var request = CreateRequest(ContractRequest);

            using var response = await client.SendAsync(request);
            var body = await response.Content.ReadAsStringAsync();

            Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
            Assert.DoesNotContain("configured evaluation fault", body, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("InjectedFaultException", body, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static HttpRequestMessage CreateRequest(string json)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/evaluate")
        {
            Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json"),
        };
        request.Headers.Add("x-correlation-id", "550e8400-e29b-41d4-a716-446655440000");
        request.Headers.Add(
            "traceparent",
            "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01");
        return request;
    }

    private sealed class AppBFactory(string? faultPath = null) : WebApplicationFactory<Program>
    {
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.ConfigureAppConfiguration((_, configuration) =>
            {
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["RISK_REGION"] = "us-central1",
                    ["RISK_CLUSTER"] = "gke-risk-usc1",
                    ["SERVICE_VERSION"] = "test-sha",
                    ["GOOGLE_CLOUD_PROJECT"] = "test-project",
                    ["FAULT_CONFIG_PATH"] = faultPath ?? Path.Combine(
                        Path.GetTempPath(),
                        $"missing-app-b-fault-{Guid.NewGuid():N}.json"),
                });
            });
        }
    }
}

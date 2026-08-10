using AppB;
using Microsoft.Extensions.Configuration;

namespace AppB.Tests;

public sealed class ExchangeRateProviderTests
{
    private readonly ExchangeRateProvider _provider = new(
        new AppIdentity("us-central1", "gke-currency-usc1", "abc123", "test-project"));

    [Fact]
    public void ReturnsTheFrozenSyntheticRateContract()
    {
        var result = _provider.GetRates();

        Assert.Equal("USD", result.BaseCurrency);
        Assert.Equal(
            new ExchangeRateSnapshot[]
            {
                new(0.92m, 0.78m, 149.50m),
                new(0.93m, 0.79m, 150.10m),
                new(0.91m, 0.77m, 148.90m),
                new(0.92m, 0.79m, 149.80m),
                new(0.93m, 0.78m, 149.20m),
                new(0.91m, 0.78m, 150.00m),
                new(0.92m, 0.77m, 149.10m),
                new(0.93m, 0.77m, 149.70m),
                new(0.91m, 0.79m, 149.40m),
                new(0.92m, 0.78m, 149.90m),
            },
            result.RateSnapshots);
        Assert.Equal(10, result.RateSnapshots.Count);
        Assert.Equal(10, result.RateSnapshots.Distinct().Count());
        Assert.Equal("Synthetic demonstration rates - not for financial use.", result.Disclaimer);
        Assert.Equal("app-b-engine", result.ProvidedBy.Service);
        Assert.Equal("us-central1", result.ProvidedBy.Region);
        Assert.Equal("gke-currency-usc1", result.ProvidedBy.Cluster);
        Assert.Equal("abc123", result.ProvidedBy.Version);
    }

    [Fact]
    public void RepeatedCallsReturnTheSameOrderedCatalogAndIdentity()
    {
        var first = _provider.GetRates();
        var second = _provider.GetRates();

        Assert.Equal(first, second);
        Assert.Equal(first.RateSnapshots, second.RateSnapshots);
    }

    [Fact]
    public void IdentityUsesTheServiceEnvironmentContract()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["SERVICE_REGION"] = "us-east4",
                ["SERVICE_CLUSTER"] = "gke-currency-use4",
                ["SERVICE_VERSION"] = "release-sha",
                ["GOOGLE_CLOUD_PROJECT"] = "currency-project",
            })
            .Build();

        var identity = AppIdentity.FromConfiguration(configuration);

        Assert.Equal("us-east4", identity.Region);
        Assert.Equal("gke-currency-use4", identity.Cluster);
        Assert.Equal("release-sha", identity.Version);
        Assert.Equal("currency-project", identity.ProjectId);
    }
}

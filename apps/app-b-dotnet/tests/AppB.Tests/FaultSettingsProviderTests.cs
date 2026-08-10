using AppB;
using Microsoft.Extensions.Configuration;

namespace AppB.Tests;

public sealed class FaultSettingsProviderTests
{
    [Fact]
    public void ParsesFrozenFaultSchema()
    {
        var settings = FaultSettingsProvider.Parse(
            """
            {
              "injected_latency_ms": 900,
              "injected_error_rate": 1.0
            }
            """);

        Assert.Equal(900, settings.InjectedLatencyMs);
        Assert.Equal(1.0, settings.InjectedErrorRate);
    }

    [Theory]
    [InlineData(-1, 0.0)]
    [InlineData(60001, 0.0)]
    [InlineData(0, -0.1)]
    [InlineData(0, 1.1)]
    public void RejectsUnsafeFaultValues(int latencyMs, double errorRate)
    {
        var json = $$"""
            {
              "injected_latency_ms": {{latencyMs}},
              "injected_error_rate": {{errorRate}}
            }
            """;

        Assert.Throws<InvalidDataException>(() => FaultSettingsProvider.Parse(json));
    }

    [Theory]
    [InlineData("{\"injected_latency_ms\":0}")]
    [InlineData("{\"injected_error_rate\":0.0}")]
    public void RejectsMissingFaultFields(string json)
    {
        Assert.Throws<InvalidDataException>(() => FaultSettingsProvider.Parse(json));
    }

    [Fact]
    public void FailureInjectionIsDeterministicAndHonorsLimits()
    {
        const string sampleKey = "550e8400-e29b-41d4-a716-446655440000";

        Assert.False(FaultSettingsProvider.ShouldInjectFailure(sampleKey, 0.0));
        Assert.True(FaultSettingsProvider.ShouldInjectFailure(sampleKey, 1.0));
        Assert.Equal(
            FaultSettingsProvider.ShouldInjectFailure(sampleKey, 0.25),
            FaultSettingsProvider.ShouldInjectFailure(sampleKey, 0.25));
    }

    [Fact]
    public void FractionalFailureInjectionRequiresAStableSampleKey()
    {
        Assert.Throws<ArgumentException>(() =>
            FaultSettingsProvider.ShouldInjectFailure(string.Empty, 0.5));
    }

    [Fact]
    public async Task ReloadsAChangedProjectedFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"app-b-reload-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(
            path,
            """{"injected_latency_ms":0,"injected_error_rate":0.0}""");

        try
        {
            var configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["FAULT_CONFIG_PATH"] = path,
                })
                .Build();
            using var output = new StringWriter();
            var logger = new StructuredLogWriter(
                new AppIdentity("test-region", "test-cluster", "test-sha", string.Empty),
                output);
            using var provider = new FaultSettingsProvider(configuration, logger);
            await provider.StartAsync(CancellationToken.None);

            await File.WriteAllTextAsync(
                path,
                """{"injected_latency_ms":900,"injected_error_rate":1.0}""");

            for (var attempt = 0; attempt < 20 && provider.Current.InjectedErrorRate < 1.0; attempt++)
            {
                await Task.Delay(250);
            }

            await provider.StopAsync(CancellationToken.None);
            Assert.Equal(new FaultSettings(900, 1.0), provider.Current);
        }
        finally
        {
            File.Delete(path);
        }
    }
}

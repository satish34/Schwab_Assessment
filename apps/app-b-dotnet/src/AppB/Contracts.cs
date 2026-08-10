using System.Text.Json.Serialization;

namespace AppB;

public sealed record ProvidedBy(
    string Service,
    string Region,
    string Cluster,
    string Version);

public sealed record ExchangeRatesResponse(
    string BaseCurrency,
    IReadOnlyList<ExchangeRateSnapshot> RateSnapshots,
    string Disclaimer,
    ProvidedBy ProvidedBy);

public sealed record ExchangeRateSnapshot(
    [property: JsonPropertyName("EUR")] decimal Eur,
    [property: JsonPropertyName("GBP")] decimal Gbp,
    [property: JsonPropertyName("JPY")] decimal Jpy);

public sealed record HealthResponse(string Status, string Service);

public sealed record AppIdentity(
    string Region,
    string Cluster,
    string Version,
    string ProjectId)
{
    public const string ServiceName = "app-b-engine";

    public static AppIdentity FromConfiguration(IConfiguration configuration) => new(
        configuration["SERVICE_REGION"] ?? "local",
        configuration["SERVICE_CLUSTER"] ?? "local",
        configuration["SERVICE_VERSION"] ?? "dev",
        configuration["GOOGLE_CLOUD_PROJECT"] ?? string.Empty);
}

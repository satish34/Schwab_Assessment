namespace AppB;

public sealed class ExchangeRateProvider(AppIdentity identity)
{
    public const string BaseCurrency = "USD";
    public const string Disclaimer = "Synthetic demonstration rates - not for financial use.";

    private static readonly IReadOnlyList<ExchangeRateSnapshot> SyntheticRateSnapshots =
        Array.AsReadOnly<ExchangeRateSnapshot>(
        [
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
        ]);

    public ExchangeRatesResponse GetRates() => new(
        BaseCurrency,
        SyntheticRateSnapshots,
        Disclaimer,
        new ProvidedBy(
            AppIdentity.ServiceName,
            identity.Region,
            identity.Cluster,
            identity.Version));
}

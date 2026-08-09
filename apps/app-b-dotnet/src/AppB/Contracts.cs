namespace AppB;

public sealed record RiskRequest(
    string? RequestId,
    decimal? Amount,
    string? Currency,
    string? MerchantCategory,
    string? CountryCode,
    string? Channel);

public sealed record EvaluatedBy(
    string Service,
    string Region,
    string Cluster,
    string Version);

public sealed record RiskResponse(
    string RequestId,
    int Score,
    string Decision,
    IReadOnlyList<string> RulesFired,
    EvaluatedBy EvaluatedBy);

public sealed record HealthResponse(string Status, string Service);

public sealed record ValidatedRiskRequest(
    Guid RequestId,
    decimal Amount,
    string Currency,
    string MerchantCategory,
    string CountryCode,
    string Channel);

public sealed record AppIdentity(
    string Region,
    string Cluster,
    string Version,
    string ProjectId)
{
    public const string ServiceName = "app-b-engine";

    public static AppIdentity FromConfiguration(IConfiguration configuration) => new(
        configuration["RISK_REGION"] ?? "local",
        configuration["RISK_CLUSTER"] ?? "local",
        configuration["SERVICE_VERSION"] ?? "dev",
        configuration["GOOGLE_CLOUD_PROJECT"] ?? string.Empty);
}

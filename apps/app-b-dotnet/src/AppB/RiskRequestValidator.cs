namespace AppB;

public sealed record ValidationResult(
    ValidatedRiskRequest? Request,
    IReadOnlyDictionary<string, string[]> Errors)
{
    public bool IsValid => Request is not null && Errors.Count == 0;
}

public static class RiskRequestValidator
{
    public static ValidationResult Validate(RiskRequest? request)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);

        if (request is null)
        {
            errors["body"] = ["A JSON request body is required."];
            return new ValidationResult(null, errors);
        }

        var requestIdIsValid = Guid.TryParse(request.RequestId, out var requestId);
        if (!requestIdIsValid)
        {
            errors["requestId"] = ["requestId must be a UUID."];
        }

        if (request.Amount is null || request.Amount <= 0)
        {
            errors["amount"] = ["amount must be greater than zero."];
        }

        if (!IsAsciiLetters(request.Currency, 3))
        {
            errors["currency"] = ["currency must be a three-letter code."];
        }

        if (string.IsNullOrWhiteSpace(request.MerchantCategory) ||
            request.MerchantCategory.Length > 64)
        {
            errors["merchantCategory"] = ["merchantCategory is required and may not exceed 64 characters."];
        }

        if (!IsAsciiLetters(request.CountryCode, 2))
        {
            errors["countryCode"] = ["countryCode must be a two-letter code."];
        }

        if (string.IsNullOrWhiteSpace(request.Channel) || request.Channel.Length > 64)
        {
            errors["channel"] = ["channel is required and may not exceed 64 characters."];
        }

        if (errors.Count > 0)
        {
            return new ValidationResult(null, errors);
        }

        return new ValidationResult(
            new ValidatedRiskRequest(
                requestId,
                request.Amount!.Value,
                request.Currency!.ToUpperInvariant(),
                request.MerchantCategory!.Trim().ToUpperInvariant(),
                request.CountryCode!.ToUpperInvariant(),
                request.Channel!.Trim().ToUpperInvariant()),
            errors);
    }

    private static bool IsAsciiLetters(string? value, int length) =>
        value is not null &&
        value.Length == length &&
        value.All(character =>
            character is >= 'A' and <= 'Z' or >= 'a' and <= 'z');
}

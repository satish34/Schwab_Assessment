using AppB;

namespace AppB.Tests;

public sealed class RiskRequestValidatorTests
{
    [Fact]
    public void ValidRequestIsNormalized()
    {
        var result = RiskRequestValidator.Validate(new RiskRequest(
            "550e8400-e29b-41d4-a716-446655440000",
            1250.50m,
            "usd",
            "electronics",
            "us",
            "card_not_present"));

        Assert.True(result.IsValid);
        Assert.NotNull(result.Request);
        Assert.Equal("USD", result.Request.Currency);
        Assert.Equal("ELECTRONICS", result.Request.MerchantCategory);
        Assert.Equal("US", result.Request.CountryCode);
        Assert.Equal("CARD_NOT_PRESENT", result.Request.Channel);
    }

    [Fact]
    public void InvalidFieldsAreReportedTogether()
    {
        var result = RiskRequestValidator.Validate(new RiskRequest(
            "not-a-uuid",
            0m,
            "US",
            string.Empty,
            "USA",
            string.Empty));

        Assert.False(result.IsValid);
        Assert.Equal(
            ["requestId", "amount", "currency", "merchantCategory", "countryCode", "channel"],
            result.Errors.Keys);
    }
}

using AppB;

namespace AppB.Tests;

public sealed class RiskEvaluatorTests
{
    private readonly RiskEvaluator _evaluator = new(
        new AppIdentity("us-central1", "gke-risk-usc1", "abc123", "test-project"));

    [Fact]
    public void ExactContractRequestProducesExpectedReview()
    {
        var request = new ValidatedRiskRequest(
            Guid.Parse("550e8400-e29b-41d4-a716-446655440000"),
            1250.50m,
            "USD",
            "ELECTRONICS",
            "US",
            "CARD_NOT_PRESENT");

        var result = _evaluator.Evaluate(request);

        Assert.Equal(48, result.Score);
        Assert.Equal("REVIEW", result.Decision);
        Assert.Equal(["CARD_NOT_PRESENT", "AMOUNT_OVER_1000"], result.RulesFired);
        Assert.Equal("app-b-engine", result.EvaluatedBy.Service);
        Assert.Equal("us-central1", result.EvaluatedBy.Region);
        Assert.Equal("gke-risk-usc1", result.EvaluatedBy.Cluster);
        Assert.Equal("abc123", result.EvaluatedBy.Version);
    }

    [Theory]
    [InlineData(0, "APPROVE")]
    [InlineData(39, "APPROVE")]
    [InlineData(40, "REVIEW")]
    [InlineData(69, "REVIEW")]
    [InlineData(70, "DECLINE")]
    [InlineData(100, "DECLINE")]
    public void DecisionBoundariesAreStable(int score, string expected)
    {
        Assert.Equal(expected, RiskEvaluator.Classify(score));
    }

    [Fact]
    public void AmountOver1000RuleStartsImmediatelyAboveThreshold()
    {
        var below = _evaluator.Evaluate(CreateRequest(amount: 999.99m));
        var exact = _evaluator.Evaluate(CreateRequest(amount: 1_000m));
        var above = _evaluator.Evaluate(CreateRequest(amount: 1_000.01m));

        Assert.Equal(13, below.Score);
        Assert.Equal(below.Score, exact.Score);
        Assert.DoesNotContain("AMOUNT_OVER_1000", below.RulesFired);
        Assert.DoesNotContain("AMOUNT_OVER_1000", exact.RulesFired);
        Assert.Equal(20, above.Score - exact.Score);
        Assert.Contains("AMOUNT_OVER_1000", above.RulesFired);
    }

    [Fact]
    public void AmountOver10000RuleStartsImmediatelyAboveThreshold()
    {
        var below = _evaluator.Evaluate(CreateRequest(amount: 9_999.99m));
        var exact = _evaluator.Evaluate(CreateRequest(amount: 10_000m));
        var above = _evaluator.Evaluate(CreateRequest(amount: 10_000.01m));

        Assert.Equal(33, below.Score);
        Assert.Equal(below.Score, exact.Score);
        Assert.Contains("AMOUNT_OVER_1000", exact.RulesFired);
        Assert.DoesNotContain("AMOUNT_OVER_10000", below.RulesFired);
        Assert.DoesNotContain("AMOUNT_OVER_10000", exact.RulesFired);
        Assert.Equal(25, above.Score - exact.Score);
        Assert.Contains("AMOUNT_OVER_10000", above.RulesFired);
    }

    [Fact]
    public void NonUsCountryAddsOnlyItsExpectedRiskDelta()
    {
        var domestic = _evaluator.Evaluate(CreateRequest(countryCode: "US"));
        var international = _evaluator.Evaluate(CreateRequest(countryCode: "CA"));

        Assert.Equal(20, international.Score - domestic.Score);
        Assert.DoesNotContain("NON_US_COUNTRY", domestic.RulesFired);
        Assert.Equal(["NON_US_COUNTRY"], international.RulesFired);
    }

    [Theory]
    [InlineData("CASH_ADVANCE")]
    [InlineData("CRYPTOCURRENCY")]
    [InlineData("GAMBLING")]
    public void HighRiskMerchantCategoryAddsOnlyItsExpectedRiskDelta(string merchantCategory)
    {
        var ordinary = _evaluator.Evaluate(CreateRequest(merchantCategory: "ELECTRONICS"));
        var highRisk = _evaluator.Evaluate(CreateRequest(merchantCategory: merchantCategory));

        Assert.Equal(20, highRisk.Score - ordinary.Score);
        Assert.DoesNotContain("HIGH_RISK_MERCHANT_CATEGORY", ordinary.RulesFired);
        Assert.Equal(["HIGH_RISK_MERCHANT_CATEGORY"], highRisk.RulesFired);
    }

    [Fact]
    public void SameRequestAlwaysProducesSameEvaluation()
    {
        var request = new ValidatedRiskRequest(
            Guid.Parse("3f52a98a-7467-4ad9-94e0-a063f11ea34f"),
            20_000m,
            "USD",
            "GAMBLING",
            "GB",
            "CARD_NOT_PRESENT");

        var first = _evaluator.Evaluate(request);
        var second = _evaluator.Evaluate(request);

        Assert.Equal(first.RequestId, second.RequestId);
        Assert.Equal(first.Score, second.Score);
        Assert.Equal(first.Decision, second.Decision);
        Assert.Equal(first.RulesFired, second.RulesFired);
        Assert.Equal(first.EvaluatedBy, second.EvaluatedBy);
        Assert.Equal("DECLINE", first.Decision);
        Assert.Equal(100, first.Score);
    }

    private static ValidatedRiskRequest CreateRequest(
        decimal amount = 100m,
        string merchantCategory = "ELECTRONICS",
        string countryCode = "US") => new(
            Guid.Parse("550e8400-e29b-41d4-a716-446655440000"),
            amount,
            "USD",
            merchantCategory,
            countryCode,
            "CARD_PRESENT");
}

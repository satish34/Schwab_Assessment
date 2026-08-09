using System.Security.Cryptography;
using System.Text;

namespace AppB;

public sealed class RiskEvaluator(AppIdentity identity)
{
    private static readonly HashSet<string> HighRiskMerchantCategories =
        new(StringComparer.Ordinal)
        {
            "CASH_ADVANCE",
            "CRYPTOCURRENCY",
            "GAMBLING",
        };

    public RiskResponse Evaluate(ValidatedRiskRequest request)
    {
        var rules = new List<string>();
        var score = 10 + StableRequestComponent(request.RequestId);

        if (request.Channel == "CARD_NOT_PRESENT")
        {
            score += 15;
            rules.Add("CARD_NOT_PRESENT");
        }

        if (request.Amount > 1_000m)
        {
            score += 20;
            rules.Add("AMOUNT_OVER_1000");
        }

        if (request.Amount > 10_000m)
        {
            score += 25;
            rules.Add("AMOUNT_OVER_10000");
        }

        if (request.CountryCode != "US")
        {
            score += 20;
            rules.Add("NON_US_COUNTRY");
        }

        if (HighRiskMerchantCategories.Contains(request.MerchantCategory))
        {
            score += 20;
            rules.Add("HIGH_RISK_MERCHANT_CATEGORY");
        }

        score = Math.Clamp(score, 0, 100);

        return new RiskResponse(
            request.RequestId.ToString("D"),
            score,
            Classify(score),
            rules,
            new EvaluatedBy(
                AppIdentity.ServiceName,
                identity.Region,
                identity.Cluster,
                identity.Version));
    }

    public static string Classify(int score) => score switch
    {
        < 0 or > 100 => throw new ArgumentOutOfRangeException(nameof(score)),
        < 40 => "APPROVE",
        < 70 => "REVIEW",
        _ => "DECLINE",
    };

    private static int StableRequestComponent(Guid requestId)
    {
        var canonicalId = requestId.ToString("D");
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(canonicalId));
        return hash[0] % 10;
    }
}

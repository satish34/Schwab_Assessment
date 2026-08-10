package com.schwab.exchange.gateway;

import com.schwab.exchange.gateway.api.model.CurrencyRates;
import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;
import com.schwab.exchange.gateway.api.model.ProvidedBy;
import java.math.BigDecimal;
import java.util.List;
import java.util.StringJoiner;

public final class TestExchangeRateFixtures {

  public static final String DISCLAIMER = "Synthetic demonstration rates - not for financial use.";

  private static final List<String> SNAPSHOT_JSON =
      List.of(
          "{\"EUR\":0.92,\"GBP\":0.78,\"JPY\":149.50}",
          "{\"EUR\":0.93,\"GBP\":0.79,\"JPY\":150.10}",
          "{\"EUR\":0.91,\"GBP\":0.77,\"JPY\":148.90}",
          "{\"EUR\":0.92,\"GBP\":0.79,\"JPY\":149.80}",
          "{\"EUR\":0.93,\"GBP\":0.78,\"JPY\":149.20}",
          "{\"EUR\":0.91,\"GBP\":0.78,\"JPY\":150.00}",
          "{\"EUR\":0.92,\"GBP\":0.77,\"JPY\":149.10}",
          "{\"EUR\":0.93,\"GBP\":0.77,\"JPY\":149.70}",
          "{\"EUR\":0.91,\"GBP\":0.79,\"JPY\":149.40}",
          "{\"EUR\":0.92,\"GBP\":0.78,\"JPY\":149.90}");

  private static final List<CurrencyRates> SNAPSHOTS =
      List.of(
          rates("0.92", "0.78", "149.50"),
          rates("0.93", "0.79", "150.10"),
          rates("0.91", "0.77", "148.90"),
          rates("0.92", "0.79", "149.80"),
          rates("0.93", "0.78", "149.20"),
          rates("0.91", "0.78", "150.00"),
          rates("0.92", "0.77", "149.10"),
          rates("0.93", "0.77", "149.70"),
          rates("0.91", "0.79", "149.40"),
          rates("0.92", "0.78", "149.90"));

  public static final String RESPONSE_JSON =
      responseJsonWithSnapshotIndexes(0, 1, 2, 3, 4, 5, 6, 7, 8, 9);

  private TestExchangeRateFixtures() {}

  public static ExchangeRatesResponse response() {
    return new ExchangeRatesResponse(
        "USD",
        SNAPSHOTS,
        DISCLAIMER,
        new ProvidedBy("app-b-engine", "us-central1", "gke-risk-usc1", "abc123"));
  }

  public static String responseJsonWithSnapshotIndexes(int... indexes) {
    StringJoiner snapshots = new StringJoiner(",", "[", "]");
    for (int index : indexes) {
      snapshots.add(SNAPSHOT_JSON.get(index));
    }
    return responseJsonWithSnapshots(snapshots.toString());
  }

  public static String responseJsonWithSnapshots(String snapshotsJson) {
    return """
        {
          "baseCurrency":"USD",
          "rateSnapshots":%s,
          "disclaimer":"Synthetic demonstration rates - not for financial use.",
          "providedBy":{
            "service":"app-b-engine",
            "region":"us-central1",
            "cluster":"gke-risk-usc1",
            "version":"abc123"
          }
        }
        """
        .formatted(snapshotsJson);
  }

  private static CurrencyRates rates(String eur, String gbp, String jpy) {
    return new CurrencyRates(new BigDecimal(eur), new BigDecimal(gbp), new BigDecimal(jpy));
  }
}

package com.schwab.exchange.gateway.contract;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.exchange.gateway.TestExchangeRateFixtures;
import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;
import java.util.Set;
import org.junit.jupiter.api.Test;

class ExchangeRateContractTest {

  private final ObjectMapper objectMapper =
      new ObjectMapper().enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);

  @Test
  void canonicalResponseMatchesTheExactExchangeRateSchema() throws Exception {
    JsonNode json = objectMapper.readTree(TestExchangeRateFixtures.RESPONSE_JSON);
    ExchangeRatesResponse response =
        objectMapper.readValue(TestExchangeRateFixtures.RESPONSE_JSON, ExchangeRatesResponse.class);

    assertThat(json.properties())
        .extracting(entry -> entry.getKey())
        .containsExactlyInAnyOrderElementsOf(
            Set.of("baseCurrency", "rateSnapshots", "disclaimer", "providedBy"));
    assertThat(json.path("rateSnapshots").isArray()).isTrue();
    assertThat(json.path("rateSnapshots")).hasSize(10);
    for (JsonNode snapshot : json.path("rateSnapshots")) {
      assertThat(snapshot.properties())
          .extracting(entry -> entry.getKey())
          .containsExactlyInAnyOrder("EUR", "GBP", "JPY");
    }
    assertThat(response.baseCurrency()).isEqualTo("USD");
    assertThat(response.rateSnapshots())
        .extracting(snapshot -> snapshot.eur().toPlainString())
        .containsExactly(
            "0.92", "0.93", "0.91", "0.92", "0.93", "0.91", "0.92", "0.93", "0.91", "0.92");
    assertThat(response.rateSnapshots())
        .extracting(snapshot -> snapshot.gbp().toPlainString())
        .containsExactly(
            "0.78", "0.79", "0.77", "0.79", "0.78", "0.78", "0.77", "0.77", "0.79", "0.78");
    assertThat(response.rateSnapshots())
        .extracting(snapshot -> snapshot.jpy().toPlainString())
        .containsExactly(
            "149.50", "150.10", "148.90", "149.80", "149.20", "150.00", "149.10", "149.70",
            "149.40", "149.90");
    assertThat(response.disclaimer())
        .isEqualTo("Synthetic demonstration rates - not for financial use.");
    assertThat(response.providedBy().service()).isEqualTo("app-b-engine");

    String serializedText = objectMapper.writeValueAsString(response);
    assertThat(serializedText)
        .contains("\"JPY\":149.50")
        .contains("\"JPY\":150.00")
        .contains("\"JPY\":149.90");
    JsonNode serialized = objectMapper.readTree(serializedText);
    assertThat(serialized.has("rates")).isFalse();
    assertThat(serialized.has("requestId")).isFalse();
    assertThat(serialized.has("decision")).isFalse();
  }
}

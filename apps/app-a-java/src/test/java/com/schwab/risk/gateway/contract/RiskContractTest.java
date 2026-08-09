package com.schwab.risk.gateway.contract;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.risk.gateway.api.model.Decision;
import com.schwab.risk.gateway.api.model.RiskRequest;
import com.schwab.risk.gateway.api.model.RiskResponse;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import java.util.Set;
import org.junit.jupiter.api.Test;

class RiskContractTest {

  private static final String REQUEST_JSON =
      """
      {
        "requestId":"550e8400-e29b-41d4-a716-446655440000",
        "amount":1250.50,
        "currency":"USD",
        "merchantCategory":"ELECTRONICS",
        "countryCode":"US",
        "channel":"CARD_NOT_PRESENT"
      }
      """;
  private static final String RESPONSE_JSON =
      """
      {
        "requestId":"550e8400-e29b-41d4-a716-446655440000",
        "score":48,
        "decision":"REVIEW",
        "rulesFired":["CARD_NOT_PRESENT","AMOUNT_OVER_1000"],
        "evaluatedBy":{
          "service":"app-b-engine",
          "region":"us-central1",
          "cluster":"gke-risk-usc1",
          "version":"abc123"
        }
      }
      """;

  private final ObjectMapper objectMapper =
      new ObjectMapper().enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
  private final Validator validator = Validation.buildDefaultValidatorFactory().getValidator();

  @Test
  void canonicalRequestMatchesTheFrozenSchemaAndValidates() throws Exception {
    JsonNode json = objectMapper.readTree(REQUEST_JSON);
    RiskRequest request = objectMapper.readValue(REQUEST_JSON, RiskRequest.class);

    assertThat(json.properties())
        .extracting(entry -> entry.getKey())
        .containsExactlyInAnyOrderElementsOf(
            Set.of(
                "requestId", "amount", "currency", "merchantCategory", "countryCode", "channel"));
    assertThat(json.get("amount").isNumber()).isTrue();
    assertThat(validator.validate(request)).isEmpty();
  }

  @Test
  void canonicalResponseMatchesTheFrozenSchema() throws Exception {
    JsonNode json = objectMapper.readTree(RESPONSE_JSON);
    RiskResponse response = objectMapper.readValue(RESPONSE_JSON, RiskResponse.class);

    assertThat(json.properties())
        .extracting(entry -> entry.getKey())
        .containsExactlyInAnyOrderElementsOf(
            Set.of("requestId", "score", "decision", "rulesFired", "evaluatedBy"));
    assertThat(json.get("score").isIntegralNumber()).isTrue();
    assertThat(json.get("rulesFired").isArray()).isTrue();
    assertThat(json.get("evaluatedBy").isObject()).isTrue();
    assertThat(response.decision()).isEqualTo(Decision.REVIEW);
  }
}

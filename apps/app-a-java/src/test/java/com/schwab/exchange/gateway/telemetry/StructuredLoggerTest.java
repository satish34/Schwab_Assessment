package com.schwab.exchange.gateway.telemetry;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.exchange.gateway.TestExchangeRateFixtures;
import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;
import com.schwab.exchange.gateway.client.DownstreamResult;
import com.schwab.exchange.gateway.config.AppAProperties;
import java.net.URI;
import java.time.Duration;
import java.util.Set;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class StructuredLoggerTest {

  private static final Set<String> EXPECTED_FIELDS =
      Set.of(
          "severity",
          "message",
          "log_type",
          "service",
          "service_version",
          "region",
          "cluster",
          "correlation_id",
          "trace_id",
          "route",
          "method",
          "status_code",
          "latency_ms",
          "downstream_latency_ms",
          "decision",
          "error_type",
          "stack_trace",
          "is_test",
          "logging.googleapis.com/trace");

  private ObjectMapper objectMapper;
  private StructuredLogger logger;
  private TraceContext traceContext;

  @BeforeEach
  void setUp() {
    objectMapper = new ObjectMapper();
    TraceContextResolver resolver = new TraceContextResolver();
    AppAProperties properties =
        new AppAProperties(
            "us-central1",
            "gke-risk-usc1",
            "abc123",
            URI.create("http://app-b-engine:8080"),
            "schwab-assessment-gke",
            Duration.ofMillis(500),
            Duration.ofMillis(750),
            true,
            2000,
            3,
            5);
    logger = new StructuredLogger(objectMapper, properties, resolver);
    traceContext =
        new TraceContext(
            "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824",
            "4bf92f3577b34da6a3ce929d0e0e4736",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
  }

  @Test
  void representativeRequestLineHasStableNamesAndTypes() throws Exception {
    RequestTelemetry telemetry = new RequestTelemetry(traceContext);
    telemetry.markSuccess(31, "RATES_RETURNED");

    String line = logger.serialize(logger.createRequestEvent(telemetry, 200, 42, "GET"));
    JsonNode event = objectMapper.readTree(line);

    assertThat(event.properties())
        .extracting(entry -> entry.getKey())
        .containsExactlyInAnyOrderElementsOf(EXPECTED_FIELDS);
    assertThat(event.get("status_code").isIntegralNumber()).isTrue();
    assertThat(event.get("latency_ms").isIntegralNumber()).isTrue();
    assertThat(event.get("downstream_latency_ms").isIntegralNumber()).isTrue();
    assertThat(event.get("is_test").isBoolean()).isTrue();
    assertThat(event.get("trace_id").asText()).matches("[0-9a-f]{32}");
    assertThat(event.get("route").asText()).isEqualTo("/api/exchange-rates");
    assertThat(event.get("method").asText()).isEqualTo("GET");
    assertThat(event.get("decision").asText()).isEqualTo("RATES_RETURNED");
    assertThat(event.get("message").asText()).isEqualTo("exchange rates returned");
    assertThat(event.get("logging.googleapis.com/trace").asText())
        .isEqualTo("projects/schwab-assessment-gke/traces/4bf92f3577b34da6a3ce929d0e0e4736");
  }

  @Test
  void errorEventContainsAParseableSanitizedJavaStack() throws Exception {
    RequestTelemetry telemetry = new RequestTelemetry(traceContext);
    telemetry.markFailure(
        "dependency_unavailable", 9, new RuntimeException("sensitive downstream text"));

    JsonNode event =
        objectMapper.readTree(
            logger.serialize(logger.createRequestEvent(telemetry, 503, 12, "GET")));

    assertThat(event.get("severity").asText()).isEqualTo("ERROR");
    assertThat(event.get("stack_trace").asText())
        .startsWith("java.lang.RuntimeException: request processing failed")
        .contains("\tat ")
        .doesNotContain("sensitive downstream text");
  }

  @Test
  void dependencyProbeUsesTheSameInternalGetContract() throws Exception {
    ExchangeRatesResponse response = TestExchangeRateFixtures.response();

    StructuredLogEvent event =
        logger.createDependencyProbeSuccessEvent(traceContext, new DownstreamResult(response, 7));
    JsonNode json = objectMapper.readTree(logger.serialize(event));
    assertThat(json.get("route").asText()).isEqualTo("/internal/exchange-rates");
    assertThat(json.get("method").asText()).isEqualTo("GET");
    assertThat(json.get("decision").asText()).isEqualTo("RATES_RETURNED");
  }

  @Test
  void startupSeedIncludesTheCompleteSchema() throws Exception {
    JsonNode event = objectMapper.readTree(logger.serialize(logger.createSchemaSeedEvent()));

    assertThat(event.properties())
        .extracting(entry -> entry.getKey())
        .containsExactlyInAnyOrderElementsOf(EXPECTED_FIELDS);
    assertThat(event.get("log_type").asText()).isEqualTo("schema_seed");
    assertThat(event.get("status_code").isIntegralNumber()).isTrue();
  }
}

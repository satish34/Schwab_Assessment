package com.schwab.risk.gateway.telemetry;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

@SpringBootTest(properties = "risk.probe-enabled=false")
@ExtendWith(OutputCaptureExtension.class)
class ConsoleLoggingIntegrationTest {

  private static final Set<String> FROZEN_FIELDS =
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

  private static final Logger LOGGER = LoggerFactory.getLogger(ConsoleLoggingIntegrationTest.class);

  @Autowired private ObjectMapper objectMapper;

  @Test
  void writesFrameworkErrorsWithMultilineExceptionsAsOneJsonLine(CapturedOutput output)
      throws Exception {
    int outputStart = output.getAll().length();
    LOGGER.error("framework-json-regression", new IllegalStateException("first line\nsecond line"));

    List<String> eventLines =
        output.getAll().substring(outputStart).lines().filter(line -> !line.isBlank()).toList();

    assertThat(eventLines).hasSize(1);
    JsonNode event = objectMapper.readTree(eventLines.getFirst());
    assertFrozenFrameworkSchema(event);
    assertThat(event.path("message").asText()).isEqualTo("framework-json-regression");
    assertThat(event.path("severity").asText()).isEqualTo("ERROR");
    assertThat(event.path("stack_trace").asText())
        .startsWith("java.lang.IllegalStateException: framework processing failed")
        .contains("\tat ")
        .doesNotContain("first line", "second line");
  }

  @Test
  void mapsFrameworkWarnToCloudWarning(CapturedOutput output) throws Exception {
    int outputStart = output.getAll().length();
    LOGGER.warn("framework-warning-regression");

    List<String> eventLines =
        output.getAll().substring(outputStart).lines().filter(line -> !line.isBlank()).toList();

    assertThat(eventLines).hasSize(1);
    JsonNode event = objectMapper.readTree(eventLines.getFirst());
    assertFrozenFrameworkSchema(event);
    assertThat(event.path("severity").asText()).isEqualTo("WARNING");
    assertThat(event.path("message").asText()).isEqualTo("framework-warning-regression");
    assertThat(event.path("stack_trace").asText()).isEmpty();
  }

  private static void assertFrozenFrameworkSchema(JsonNode event) {
    assertThat(event.properties())
        .extracting(entry -> entry.getKey())
        .containsExactlyInAnyOrderElementsOf(FROZEN_FIELDS);
    assertThat(event.path("log_type").asText()).isEqualTo("lifecycle");
    assertThat(event.path("service").asText()).isEqualTo("app-a-gateway");
    assertThat(event.path("service_version").asText()).isEqualTo("dev");
    assertThat(event.path("region").asText()).isEqualTo("local");
    assertThat(event.path("cluster").asText()).isEqualTo("local");
    assertThat(event.path("status_code").isIntegralNumber()).isTrue();
    assertThat(event.path("latency_ms").isIntegralNumber()).isTrue();
    assertThat(event.path("downstream_latency_ms").isIntegralNumber()).isTrue();
    assertThat(event.path("is_test").isBoolean()).isTrue();
    assertThat(event.has("level")).isFalse();
    assertThat(event.has("@timestamp")).isFalse();
  }
}

package com.schwab.risk.gateway.client;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.ExpectedCount.once;
import static org.springframework.test.web.client.ExpectedCount.times;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.schwab.risk.gateway.api.model.RiskRequest;
import com.schwab.risk.gateway.telemetry.TraceContext;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import java.math.BigDecimal;
import java.net.SocketTimeoutException;
import java.time.Duration;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

class AppBClientTest {

  private static final UUID REQUEST_ID = UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
  private static final RiskRequest REQUEST =
      new RiskRequest(
          REQUEST_ID, new BigDecimal("1250.50"), "USD", "ELECTRONICS", "US", "CARD_NOT_PRESENT");
  private static final TraceContext TRACE_CONTEXT =
      new TraceContext(
          "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824",
          "4bf92f3577b34da6a3ce929d0e0e4736",
          "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
  private static final String VALID_RESPONSE =
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

  private MockRestServiceServer server;
  private AppBClient client;
  private CircuitBreaker circuitBreaker;

  @BeforeEach
  void setUp() {
    RestClient.Builder builder = RestClient.builder().baseUrl("http://app-b-engine:8080");
    server = MockRestServiceServer.bindTo(builder).build();
    circuitBreaker = newCircuitBreaker();
    client = new AppBClient(builder.build(), circuitBreaker);
  }

  @Test
  void forwardsRequiredHeadersAndProbeMarker() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/v1/evaluate"))
        .andExpect(header("x-correlation-id", TRACE_CONTEXT.correlationId()))
        .andExpect(header("traceparent", TRACE_CONTEXT.traceparent()))
        .andExpect(header("x-cell-probe", "true"))
        .andRespond(withSuccess(VALID_RESPONSE, MediaType.APPLICATION_JSON));

    DownstreamResult result = client.evaluate(REQUEST, TRACE_CONTEXT, true);

    assertThat(result.response().requestId()).isEqualTo(REQUEST_ID);
    assertThat(result.response().decision().name()).isEqualTo("REVIEW");
    assertThat(result.latencyMs()).isGreaterThanOrEqualTo(0);
    server.verify();
  }

  @Test
  void retriesOneTimeoutThenMapsToGatewayTimeout() {
    server
        .expect(times(2), requestTo("http://app-b-engine:8080/v1/evaluate"))
        .andRespond(
            request -> {
              throw new SocketTimeoutException("simulated read timeout");
            });

    assertThatThrownBy(() -> client.evaluate(REQUEST, TRACE_CONTEXT, false))
        .isInstanceOf(DownstreamTimeoutException.class)
        .hasMessage("Local evaluation dependency timed out");
    server.verify();
  }

  @Test
  void doesNotRetryHttpFailures() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/v1/evaluate"))
        .andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));

    assertThatThrownBy(() -> client.evaluate(REQUEST, TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class)
        .extracting("errorType")
        .isEqualTo("dependency_unavailable");
    server.verify();
  }

  @Test
  void opensCircuitAfterFiveRecordedFailures() {
    server
        .expect(times(5), requestTo("http://app-b-engine:8080/v1/evaluate"))
        .andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));

    for (int attempt = 0; attempt < 5; attempt++) {
      assertThatThrownBy(() -> client.evaluate(REQUEST, TRACE_CONTEXT, false))
          .isInstanceOf(DependencyUnavailableException.class);
    }

    assertThat(circuitBreaker.getState()).isEqualTo(CircuitBreaker.State.OPEN);
    assertThatThrownBy(() -> client.evaluate(REQUEST, TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class)
        .extracting("errorType")
        .isEqualTo("circuit_open");
    server.verify();
  }

  @Test
  void rejectsAResponseForAnotherRequest() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/v1/evaluate"))
        .andRespond(
            withSuccess(
                VALID_RESPONSE.replace(
                    REQUEST_ID.toString(), "f47ac10b-58cc-4372-a567-0e02b2c3d479"),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.evaluate(REQUEST, TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsAResponseWithNoScore() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/v1/evaluate"))
        .andRespond(
            withSuccess(VALID_RESPONSE.replace("\"score\":48,", ""), MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.evaluate(REQUEST, TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class)
        .extracting("errorType")
        .isEqualTo("dependency_unavailable");
    server.verify();
  }

  private static CircuitBreaker newCircuitBreaker() {
    CircuitBreakerConfig config =
        CircuitBreakerConfig.custom()
            .failureRateThreshold(50.0f)
            .minimumNumberOfCalls(5)
            .slidingWindowSize(10)
            .permittedNumberOfCallsInHalfOpenState(5)
            .waitDurationInOpenState(Duration.ofSeconds(10))
            .build();
    return CircuitBreaker.of("test-app-b", config);
  }
}

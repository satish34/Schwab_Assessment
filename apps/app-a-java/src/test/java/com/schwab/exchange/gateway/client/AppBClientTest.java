package com.schwab.exchange.gateway.client;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.ExpectedCount.once;
import static org.springframework.test.web.client.ExpectedCount.times;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.headerDoesNotExist;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.schwab.exchange.gateway.TestExchangeRateFixtures;
import com.schwab.exchange.gateway.telemetry.TraceContext;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import java.net.SocketTimeoutException;
import java.time.Duration;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

class AppBClientTest {

  private static final TraceContext TRACE_CONTEXT =
      new TraceContext(
          "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824",
          "4bf92f3577b34da6a3ce929d0e0e4736",
          "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
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
  void getsRatesAndForwardsRequiredHeadersAndProbeMarker() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andExpect(method(HttpMethod.GET))
        .andExpect(header("x-correlation-id", TRACE_CONTEXT.correlationId()))
        .andExpect(header("traceparent", TRACE_CONTEXT.traceparent()))
        .andExpect(header("x-cell-probe", "true"))
        .andRespond(
            withSuccess(TestExchangeRateFixtures.RESPONSE_JSON, MediaType.APPLICATION_JSON));

    DownstreamResult result = client.getExchangeRates(TRACE_CONTEXT, true);

    assertThat(result.response().baseCurrency()).isEqualTo("USD");
    assertThat(result.response().rateSnapshots()).hasSize(10);
    assertThat(result.response().rateSnapshots().getFirst().eur().toPlainString())
        .isEqualTo("0.92");
    assertThat(result.response().rateSnapshots().getFirst().gbp().toPlainString())
        .isEqualTo("0.78");
    assertThat(result.response().rateSnapshots().getFirst().jpy().toPlainString())
        .isEqualTo("149.50");
    assertThat(result.response().rateSnapshots().getLast().jpy().toPlainString())
        .isEqualTo("149.90");
    assertThat(result.response().providedBy().service()).isEqualTo("app-b-engine");
    assertThat(result.latencyMs()).isGreaterThanOrEqualTo(0);
    server.verify();
  }

  @Test
  void omitsTheProbeMarkerForCustomerTraffic() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andExpect(method(HttpMethod.GET))
        .andExpect(headerDoesNotExist("x-cell-probe"))
        .andRespond(
            withSuccess(TestExchangeRateFixtures.RESPONSE_JSON, MediaType.APPLICATION_JSON));

    client.getExchangeRates(TRACE_CONTEXT, false);

    server.verify();
  }

  @Test
  void retriesOneTimeoutThenMapsToGatewayTimeout() {
    server
        .expect(times(2), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            request -> {
              throw new SocketTimeoutException("simulated read timeout");
            });

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DownstreamTimeoutException.class)
        .hasMessage("Local exchange-rate dependency timed out");
    server.verify();
  }

  @Test
  void doesNotRetryHttpFailures() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class)
        .extracting("errorType")
        .isEqualTo("dependency_unavailable");
    server.verify();
  }

  @Test
  void opensCircuitAfterFiveRecordedFailures() {
    server
        .expect(times(5), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));

    for (int attempt = 0; attempt < 5; attempt++) {
      assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
          .isInstanceOf(DependencyUnavailableException.class);
    }

    assertThat(circuitBreaker.getState()).isEqualTo(CircuitBreaker.State.OPEN);
    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class)
        .extracting("errorType")
        .isEqualTo("circuit_open");
    server.verify();
  }

  @Test
  void rejectsAResponseWithAMissingRate() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            withSuccess(
                TestExchangeRateFixtures.RESPONSE_JSON.replace("\"EUR\":0.92,", ""),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class)
        .extracting("errorType")
        .isEqualTo("dependency_unavailable");
    server.verify();
  }

  @Test
  void rejectsAResponseThatChangesAFrozenRate() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            withSuccess(
                TestExchangeRateFixtures.RESPONSE_JSON.replace("149.90", "149.91"),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsAnEmptySnapshotCatalog() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            withSuccess(
                TestExchangeRateFixtures.responseJsonWithSnapshotIndexes(),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsACatalogThatDoesNotContainExactlyTenSnapshots() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            withSuccess(
                TestExchangeRateFixtures.responseJsonWithSnapshotIndexes(0, 1, 2, 3, 4, 5, 6, 7, 8),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsSnapshotsInADifferentOrder() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            withSuccess(
                TestExchangeRateFixtures.responseJsonWithSnapshotIndexes(
                    1, 0, 2, 3, 4, 5, 6, 7, 8, 9),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsAResponseWithoutProviderMetadata() {
    server
        .expect(once(), requestTo("http://app-b-engine:8080/internal/exchange-rates"))
        .andRespond(
            withSuccess(
                TestExchangeRateFixtures.RESPONSE_JSON.replace("\"service\":\"app-b-engine\",", ""),
                MediaType.APPLICATION_JSON));

    assertThatThrownBy(() -> client.getExchangeRates(TRACE_CONTEXT, false))
        .isInstanceOf(DependencyUnavailableException.class);
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

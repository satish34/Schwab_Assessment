package com.schwab.risk.gateway.client;

import com.schwab.risk.gateway.api.model.EvaluatedBy;
import com.schwab.risk.gateway.api.model.RiskRequest;
import com.schwab.risk.gateway.api.model.RiskResponse;
import com.schwab.risk.gateway.telemetry.TraceContext;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import java.net.SocketTimeoutException;
import java.net.http.HttpTimeoutException;
import java.util.Objects;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

@Component
public class AppBClient {

  private static final int MAX_RETRIES = 1;

  private final RestClient restClient;
  private final CircuitBreaker circuitBreaker;

  public AppBClient(RestClient appBRestClient, CircuitBreaker appBCircuitBreaker) {
    this.restClient = appBRestClient;
    this.circuitBreaker = appBCircuitBreaker;
  }

  public DownstreamResult evaluate(
      RiskRequest request, TraceContext traceContext, boolean cellProbe) {
    long startedAt = System.nanoTime();
    try {
      RiskResponse response =
          circuitBreaker.executeSupplier(
              () -> {
                RiskResponse body = executeWithBoundedRetry(request, traceContext, cellProbe);
                validateResponse(request, body);
                return body;
              });
      return new DownstreamResult(response, elapsedMillis(startedAt));
    } catch (CallNotPermittedException exception) {
      throw new DependencyUnavailableException("circuit_open", 0, exception);
    } catch (ResourceAccessException exception) {
      long latencyMs = elapsedMillis(startedAt);
      if (isTimeout(exception)) {
        throw new DownstreamTimeoutException(latencyMs, exception);
      }
      throw new DependencyUnavailableException("dependency_unavailable", latencyMs, exception);
    } catch (RestClientException | InvalidDownstreamResponseException exception) {
      throw new DependencyUnavailableException(
          "dependency_unavailable", elapsedMillis(startedAt), exception);
    }
  }

  private RiskResponse executeWithBoundedRetry(
      RiskRequest request, TraceContext traceContext, boolean cellProbe) {
    int attempt = 0;
    while (true) {
      try {
        return restClient
            .post()
            .uri("/v1/evaluate")
            .contentType(MediaType.APPLICATION_JSON)
            .headers(
                headers -> {
                  headers.set("x-correlation-id", traceContext.correlationId());
                  headers.set("traceparent", traceContext.traceparent());
                  if (cellProbe) {
                    headers.set("x-cell-probe", "true");
                  }
                })
            .body(request)
            .retrieve()
            .body(RiskResponse.class);
      } catch (ResourceAccessException exception) {
        if (attempt >= MAX_RETRIES) {
          throw exception;
        }
        attempt++;
      }
    }
  }

  private static void validateResponse(RiskRequest request, RiskResponse response) {
    if (response == null
        || !Objects.equals(request.requestId(), response.requestId())
        || response.score() == null
        || response.score() < 0
        || response.score() > 100
        || response.decision() == null
        || response.rulesFired() == null
        || !validEvaluatedBy(response.evaluatedBy())) {
      throw new InvalidDownstreamResponseException();
    }
  }

  private static boolean validEvaluatedBy(EvaluatedBy evaluatedBy) {
    return evaluatedBy != null
        && "app-b-engine".equals(evaluatedBy.service())
        && hasText(evaluatedBy.region())
        && hasText(evaluatedBy.cluster())
        && hasText(evaluatedBy.version());
  }

  private static boolean hasText(String value) {
    return value != null && !value.isBlank();
  }

  private static boolean isTimeout(Throwable throwable) {
    Throwable current = throwable;
    while (current != null) {
      if (current instanceof SocketTimeoutException
          || current instanceof HttpTimeoutException
          || current instanceof TimeoutException) {
        return true;
      }
      current = current.getCause();
    }
    return false;
  }

  private static long elapsedMillis(long startedAt) {
    return Math.max(0, TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt));
  }

  private static final class InvalidDownstreamResponseException extends RuntimeException {

    private InvalidDownstreamResponseException() {
      super("Downstream response did not match the frozen contract");
    }
  }
}

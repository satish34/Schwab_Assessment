package com.schwab.exchange.gateway.client;

import com.schwab.exchange.gateway.api.model.CurrencyRates;
import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;
import com.schwab.exchange.gateway.api.model.ProvidedBy;
import com.schwab.exchange.gateway.auth.AppBIdentityTokenProvider;
import com.schwab.exchange.gateway.auth.IdentityTokenUnavailableException;
import com.schwab.exchange.gateway.telemetry.DistributedTracing;
import com.schwab.exchange.gateway.telemetry.TraceContext;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import java.math.BigDecimal;
import java.net.SocketTimeoutException;
import java.net.http.HttpTimeoutException;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.springframework.stereotype.Component;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

@Component
public class AppBClient {

  private static final int MAX_RETRIES = 1;
  private static final String DISCLAIMER = "Synthetic demonstration rates - not for financial use.";
  private static final List<CurrencyRates> EXPECTED_RATE_SNAPSHOTS =
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

  private final RestClient restClient;
  private final CircuitBreaker circuitBreaker;
  private final AppBIdentityTokenProvider identityTokenProvider;
  private final DistributedTracing distributedTracing;

  public AppBClient(
      RestClient appBRestClient,
      CircuitBreaker appBCircuitBreaker,
      AppBIdentityTokenProvider identityTokenProvider,
      DistributedTracing distributedTracing) {
    this.restClient = appBRestClient;
    this.circuitBreaker = appBCircuitBreaker;
    this.identityTokenProvider = identityTokenProvider;
    this.distributedTracing = distributedTracing;
  }

  public DownstreamResult getExchangeRates(TraceContext traceContext, boolean cellProbe) {
    long startedAt = System.nanoTime();
    try {
      ExchangeRatesResponse response =
          circuitBreaker.executeSupplier(
              () -> {
                ExchangeRatesResponse body = executeWithBoundedRetry(traceContext, cellProbe);
                validateResponse(body);
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
    } catch (IdentityTokenUnavailableException exception) {
      throw new DependencyUnavailableException(
          "dependency_unavailable", elapsedMillis(startedAt), exception);
    } catch (RestClientException | InvalidDownstreamResponseException exception) {
      throw new DependencyUnavailableException(
          "dependency_unavailable", elapsedMillis(startedAt), exception);
    }
  }

  private ExchangeRatesResponse executeWithBoundedRetry(
      TraceContext traceContext, boolean cellProbe) {
    Optional<String> providedToken = identityTokenProvider.identityToken();
    if (providedToken == null) {
      throw new IdentityTokenUnavailableException();
    }
    final Optional<String> identityToken;
    if (identityTokenProvider.authenticationRequired()) {
      String token = providedToken.orElseThrow(IdentityTokenUnavailableException::new);
      if (token.isBlank() || token.chars().anyMatch(Character::isWhitespace)) {
        throw new IdentityTokenUnavailableException();
      }
      identityToken = providedToken;
    } else {
      identityToken = Optional.empty();
    }
    int attempt = 0;
    while (true) {
      try {
        if (cellProbe) {
          return executeRequest(traceContext, identityToken, true);
        }
        try (DistributedTracing.TraceSpan clientSpan =
            distributedTracing.startClientSpan(traceContext, false, attempt)) {
          try {
            ExchangeRatesResponse response =
                executeRequest(clientSpan.traceContext(), identityToken, false);
            clientSpan.complete(200, "");
            return response;
          } catch (ResourceAccessException exception) {
            clientSpan.complete(isTimeout(exception) ? 504 : 503, dependencyError(exception));
            throw exception;
          } catch (RestClientException exception) {
            clientSpan.complete(503, "dependency_http_error");
            throw exception;
          } catch (RuntimeException exception) {
            clientSpan.complete(503, "dependency_unavailable");
            throw exception;
          }
        }
      } catch (ResourceAccessException exception) {
        if (attempt >= MAX_RETRIES) {
          throw exception;
        }
        attempt++;
      }
    }
  }

  private ExchangeRatesResponse executeRequest(
      TraceContext traceContext, Optional<String> identityToken, boolean cellProbe) {
    return restClient
        .get()
        .uri("/internal/exchange-rates")
        .headers(
            headers -> {
              headers.set("x-correlation-id", traceContext.correlationId());
              headers.set("traceparent", traceContext.traceparent());
              if (!traceContext.traceState().isBlank()) {
                headers.set("tracestate", traceContext.traceState());
              }
              identityToken.ifPresent(headers::setBearerAuth);
              if (cellProbe) {
                headers.set("x-cell-probe", "true");
              }
            })
        .retrieve()
        .body(ExchangeRatesResponse.class);
  }

  private static String dependencyError(ResourceAccessException exception) {
    return isTimeout(exception) ? "downstream_timeout" : "dependency_unavailable";
  }

  private static void validateResponse(ExchangeRatesResponse response) {
    if (response == null
        || !"USD".equals(response.baseCurrency())
        || !DISCLAIMER.equals(response.disclaimer())
        || !validRateSnapshots(response.rateSnapshots())
        || !validProvidedBy(response.providedBy())) {
      throw new InvalidDownstreamResponseException();
    }
  }

  private static boolean validRateSnapshots(List<CurrencyRates> rateSnapshots) {
    if (rateSnapshots == null
        || rateSnapshots.isEmpty()
        || rateSnapshots.size() != EXPECTED_RATE_SNAPSHOTS.size()) {
      return false;
    }
    for (int index = 0; index < EXPECTED_RATE_SNAPSHOTS.size(); index++) {
      if (!sameRates(rateSnapshots.get(index), EXPECTED_RATE_SNAPSHOTS.get(index))) {
        return false;
      }
    }
    return true;
  }

  private static boolean sameRates(CurrencyRates actual, CurrencyRates expected) {
    return actual != null
        && sameRate(actual.eur(), expected.eur())
        && sameRate(actual.gbp(), expected.gbp())
        && sameRate(actual.jpy(), expected.jpy());
  }

  private static boolean sameRate(BigDecimal actual, BigDecimal expected) {
    return actual != null && actual.compareTo(expected) == 0;
  }

  private static boolean validProvidedBy(ProvidedBy providedBy) {
    return providedBy != null
        && "app-b-engine".equals(providedBy.service())
        && hasText(providedBy.region())
        && hasText(providedBy.cluster())
        && hasText(providedBy.version());
  }

  private static boolean hasText(String value) {
    return value != null && !value.isBlank();
  }

  private static CurrencyRates rates(String eur, String gbp, String jpy) {
    return new CurrencyRates(new BigDecimal(eur), new BigDecimal(gbp), new BigDecimal(jpy));
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
      super("Downstream exchange-rate response did not match the contract");
    }
  }
}

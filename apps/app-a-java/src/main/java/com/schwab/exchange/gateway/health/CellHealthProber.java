package com.schwab.exchange.gateway.health;

import com.schwab.exchange.gateway.client.AppBClient;
import com.schwab.exchange.gateway.client.DependencyUnavailableException;
import com.schwab.exchange.gateway.client.DownstreamResult;
import com.schwab.exchange.gateway.client.DownstreamTimeoutException;
import com.schwab.exchange.gateway.telemetry.StructuredLogger;
import com.schwab.exchange.gateway.telemetry.TraceContext;
import com.schwab.exchange.gateway.telemetry.TraceContextResolver;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(name = "exchange.probe-enabled", havingValue = "true", matchIfMissing = true)
public class CellHealthProber {

  private final AppBClient appBClient;
  private final CellHealthState cellHealthState;
  private final TraceContextResolver traceContextResolver;
  private final StructuredLogger structuredLogger;

  public CellHealthProber(
      AppBClient appBClient,
      CellHealthState cellHealthState,
      TraceContextResolver traceContextResolver,
      StructuredLogger structuredLogger) {
    this.appBClient = appBClient;
    this.cellHealthState = cellHealthState;
    this.traceContextResolver = traceContextResolver;
    this.structuredLogger = structuredLogger;
  }

  @Scheduled(
      fixedRateString = "${exchange.probe-interval-ms:2000}",
      initialDelayString = "${exchange.probe-interval-ms:2000}")
  public void probe() {
    TraceContext traceContext = traceContextResolver.resolve(null, null).context();
    try {
      DownstreamResult result = appBClient.getExchangeRates(traceContext, true);
      cellHealthState.recordSuccess();
      structuredLogger.dependencyProbeSuccess(traceContext, result);
    } catch (DownstreamTimeoutException exception) {
      cellHealthState.recordFailure();
      structuredLogger.dependencyProbeFailure(
          traceContext, 504, exception.downstreamLatencyMs(), "downstream_timeout");
    } catch (DependencyUnavailableException exception) {
      cellHealthState.recordFailure();
      structuredLogger.dependencyProbeFailure(
          traceContext, 503, exception.downstreamLatencyMs(), exception.errorType());
    } catch (RuntimeException exception) {
      cellHealthState.recordFailure();
      structuredLogger.dependencyProbeFailure(traceContext, 503, 0, "dependency_unavailable");
    }
  }
}

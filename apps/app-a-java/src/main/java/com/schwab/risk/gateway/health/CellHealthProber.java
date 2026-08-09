package com.schwab.risk.gateway.health;

import com.schwab.risk.gateway.api.model.RiskRequest;
import com.schwab.risk.gateway.client.AppBClient;
import com.schwab.risk.gateway.client.DependencyUnavailableException;
import com.schwab.risk.gateway.client.DownstreamResult;
import com.schwab.risk.gateway.client.DownstreamTimeoutException;
import com.schwab.risk.gateway.telemetry.StructuredLogger;
import com.schwab.risk.gateway.telemetry.TraceContext;
import com.schwab.risk.gateway.telemetry.TraceContextResolver;
import java.math.BigDecimal;
import java.util.UUID;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(name = "risk.probe-enabled", havingValue = "true", matchIfMissing = true)
public class CellHealthProber {

  private static final UUID PROBE_REQUEST_ID =
      UUID.fromString("00000000-0000-0000-0000-000000000001");
  private static final RiskRequest PROBE_REQUEST =
      new RiskRequest(
          PROBE_REQUEST_ID, new BigDecimal("1.00"), "USD", "ELECTRONICS", "US", "CARD_NOT_PRESENT");

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
      fixedRateString = "${risk.probe-interval-ms:2000}",
      initialDelayString = "${risk.probe-interval-ms:2000}")
  public void probe() {
    TraceContext traceContext = traceContextResolver.newTrace(PROBE_REQUEST_ID.toString());
    try {
      DownstreamResult result = appBClient.evaluate(PROBE_REQUEST, traceContext, true);
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

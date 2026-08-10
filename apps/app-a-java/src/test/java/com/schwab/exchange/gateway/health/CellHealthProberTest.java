package com.schwab.exchange.gateway.health;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.schwab.exchange.gateway.TestExchangeRateFixtures;
import com.schwab.exchange.gateway.client.AppBClient;
import com.schwab.exchange.gateway.client.DependencyUnavailableException;
import com.schwab.exchange.gateway.client.DownstreamResult;
import com.schwab.exchange.gateway.telemetry.StructuredLogger;
import com.schwab.exchange.gateway.telemetry.TraceContext;
import com.schwab.exchange.gateway.telemetry.TraceContextResolver;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class CellHealthProberTest {

  @Mock private AppBClient appBClient;
  @Mock private CellHealthState cellHealthState;
  @Mock private StructuredLogger structuredLogger;

  private CellHealthProber prober;
  private DownstreamResult result;

  @BeforeEach
  void setUp() {
    prober =
        new CellHealthProber(
            appBClient, cellHealthState, new TraceContextResolver(), structuredLogger);
    result = new DownstreamResult(TestExchangeRateFixtures.response(), 6);
  }

  @Test
  void probesTheSameExchangeRatePathWithInternallyGeneratedIds() {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(true))).thenReturn(result);

    prober.probe();

    ArgumentCaptor<TraceContext> context = ArgumentCaptor.forClass(TraceContext.class);
    verify(appBClient).getExchangeRates(context.capture(), eq(true));
    assertThat(UUID.fromString(context.getValue().correlationId())).isNotNull();
    assertThat(context.getValue().traceId()).matches("[0-9a-f]{32}");
    verify(cellHealthState).recordSuccess();
    verify(structuredLogger).dependencyProbeSuccess(context.getValue(), result);
  }

  @Test
  void recordsDependencyFailureWithoutThrowingFromTheScheduler() {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(true)))
        .thenThrow(
            new DependencyUnavailableException(
                "dependency_unavailable", 9, new RuntimeException("private detail")));

    prober.probe();

    verify(cellHealthState).recordFailure();
    verify(structuredLogger)
        .dependencyProbeFailure(
            any(TraceContext.class), eq(503), eq(9L), eq("dependency_unavailable"));
  }
}

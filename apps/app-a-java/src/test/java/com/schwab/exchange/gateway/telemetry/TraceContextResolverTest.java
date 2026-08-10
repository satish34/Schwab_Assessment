package com.schwab.exchange.gateway.telemetry;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;
import org.junit.jupiter.api.Test;

class TraceContextResolverTest {

  private static final String CORRELATION_ID = "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824";
  private static final String TRACEPARENT =
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

  private final TraceContextResolver resolver = new TraceContextResolver();

  @Test
  void preservesValidCorrelationAndTraceHeaders() {
    TraceResolution resolution = resolver.resolve(CORRELATION_ID, TRACEPARENT);

    assertThat(resolution.correlationIdValid()).isTrue();
    assertThat(resolution.context().correlationId()).isEqualTo(CORRELATION_ID);
    assertThat(resolution.context().traceId()).isEqualTo("4bf92f3577b34da6a3ce929d0e0e4736");
    assertThat(resolution.context().traceparent()).isEqualTo(TRACEPARENT);
  }

  @Test
  void generatesBothIdentifiersWhenHeadersAreAbsent() {
    TraceResolution resolution = resolver.resolve(null, null);

    assertThat(resolution.correlationIdValid()).isTrue();
    assertThat(UUID.fromString(resolution.context().correlationId()).toString())
        .isEqualTo(resolution.context().correlationId());
    assertThat(resolution.context().traceId()).matches("[0-9a-f]{32}");
    assertThat(resolution.context().traceparent()).matches("00-[0-9a-f]{32}-[0-9a-f]{16}-01");
  }

  @Test
  void rejectsInvalidCorrelationAndReplacesInvalidTraceContext() {
    TraceResolution resolution =
        resolver.resolve("not-a-uuid", "00-00000000000000000000000000000000-0000000000000000-01");

    assertThat(resolution.correlationIdValid()).isFalse();
    assertThat(UUID.fromString(resolution.context().correlationId())).isNotNull();
    assertThat(resolution.context().traceId()).matches("[0-9a-f]{32}");
    assertThat(resolution.context().traceId()).isNotEqualTo("00000000000000000000000000000000");
  }
}

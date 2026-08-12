package com.schwab.exchange.gateway.telemetry;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.propagation.TextMapGetter;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.UUID;
import java.util.function.BooleanSupplier;
import org.springframework.stereotype.Component;

@Component
public class TraceContextResolver {

  private static final SecureRandom RANDOM = new SecureRandom();
  private static final double REMOTE_PARENT_SAMPLE_RATIO = 0.1;
  private static final TextMapGetter<Map<String, String>> MAP_GETTER =
      new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(Map<String, String> carrier) {
          return carrier.keySet();
        }

        @Override
        public String get(Map<String, String> carrier, String key) {
          return carrier.get(key);
        }
      };
  private final BooleanSupplier remoteParentSampleDecision;

  public TraceContextResolver() {
    this(() -> RANDOM.nextDouble() < REMOTE_PARENT_SAMPLE_RATIO);
  }

  TraceContextResolver(BooleanSupplier remoteParentSampleDecision) {
    this.remoteParentSampleDecision = remoteParentSampleDecision;
  }

  public TraceResolution resolve(String correlationHeader, String traceparentHeader) {
    return resolve(correlationHeader, traceparentHeader, null);
  }

  public TraceResolution resolve(
      String correlationHeader, String traceparentHeader, String traceStateHeader) {
    CorrelationResolution correlation = resolveCorrelation(correlationHeader);
    RemoteTraceResolution trace =
        resolveTrace(correlation.value(), traceparentHeader, traceStateHeader);
    return new TraceResolution(trace.context(), correlation.valid(), trace.remoteParent());
  }

  public TraceContext newTrace(String correlationId) {
    return generatedTrace(correlationId, true);
  }

  public TraceContext newUnsampledTrace(String correlationId) {
    return generatedTrace(correlationId, false);
  }

  private static CorrelationResolution resolveCorrelation(String header) {
    if (header == null || header.isBlank()) {
      return new CorrelationResolution(UUID.randomUUID().toString(), true);
    }

    String candidate = header.trim();
    try {
      String canonical = UUID.fromString(candidate).toString();
      boolean valid = canonical.equalsIgnoreCase(candidate);
      return new CorrelationResolution(valid ? canonical : UUID.randomUUID().toString(), valid);
    } catch (IllegalArgumentException ignored) {
      return new CorrelationResolution(UUID.randomUUID().toString(), false);
    }
  }

  private RemoteTraceResolution resolveTrace(
      String correlationId, String traceparentHeader, String traceStateHeader) {
    if (traceparentHeader != null) {
      Map<String, String> carrier = new HashMap<>();
      carrier.put("traceparent", traceparentHeader.trim());
      if (traceStateHeader != null && !traceStateHeader.isBlank()) {
        carrier.put("tracestate", traceStateHeader.trim());
      }
      Context extracted =
          W3CTraceContextPropagator.getInstance().extract(Context.root(), carrier, MAP_GETTER);
      SpanContext spanContext = Span.fromContext(extracted).getSpanContext();
      if (spanContext.isValid() && spanContext.isRemote()) {
        boolean sampled = remoteParentSampleDecision.getAsBoolean();
        String traceparent =
            "00-"
                + spanContext.getTraceId()
                + "-"
                + spanContext.getSpanId()
                + (sampled ? "-01" : "-00");
        return new RemoteTraceResolution(
            new TraceContext(
                correlationId,
                spanContext.getTraceId(),
                traceparent,
                spanContext.getTraceState().isEmpty() ? "" : traceStateHeader.trim()),
            true);
      }
    }
    return new RemoteTraceResolution(generatedTrace(correlationId, true), false);
  }

  private static TraceContext generatedTrace(String correlationId, boolean sampled) {
    String traceId = randomHex(16);
    String spanId = randomHex(8);
    return new TraceContext(
        correlationId, traceId, "00-" + traceId + "-" + spanId + (sampled ? "-01" : "-00"));
  }

  private static String randomHex(int bytes) {
    byte[] value = new byte[bytes];
    RANDOM.nextBytes(value);
    return HexFormat.of().formatHex(value);
  }

  private record CorrelationResolution(String value, boolean valid) {}

  private record RemoteTraceResolution(TraceContext context, boolean remoteParent) {}
}

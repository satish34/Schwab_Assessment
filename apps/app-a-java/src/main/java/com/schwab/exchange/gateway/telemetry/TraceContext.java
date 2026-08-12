package com.schwab.exchange.gateway.telemetry;

public record TraceContext(
    String correlationId, String traceId, String traceparent, String traceState) {

  public TraceContext(String correlationId, String traceId, String traceparent) {
    this(correlationId, traceId, traceparent, "");
  }
}

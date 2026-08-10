package com.schwab.exchange.gateway.telemetry;

public record TraceContext(String correlationId, String traceId, String traceparent) {}

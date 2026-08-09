package com.schwab.risk.gateway.telemetry;

public record TraceContext(String correlationId, String traceId, String traceparent) {}

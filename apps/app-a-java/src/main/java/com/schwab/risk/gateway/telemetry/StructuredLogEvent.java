package com.schwab.risk.gateway.telemetry;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;

@JsonPropertyOrder({
  "severity",
  "message",
  "log_type",
  "service",
  "service_version",
  "region",
  "cluster",
  "correlation_id",
  "trace_id",
  "route",
  "method",
  "status_code",
  "latency_ms",
  "downstream_latency_ms",
  "decision",
  "error_type",
  "stack_trace",
  "is_test",
  "logging.googleapis.com/trace"
})
public record StructuredLogEvent(
    String severity,
    String message,
    @JsonProperty("log_type") String logType,
    String service,
    @JsonProperty("service_version") String serviceVersion,
    String region,
    String cluster,
    @JsonProperty("correlation_id") String correlationId,
    @JsonProperty("trace_id") String traceId,
    String route,
    String method,
    @JsonProperty("status_code") int statusCode,
    @JsonProperty("latency_ms") long latencyMs,
    @JsonProperty("downstream_latency_ms") long downstreamLatencyMs,
    String decision,
    @JsonProperty("error_type") String errorType,
    @JsonProperty("stack_trace") String stackTrace,
    @JsonProperty("is_test") boolean test,
    @JsonProperty("logging.googleapis.com/trace") String googleTrace) {}

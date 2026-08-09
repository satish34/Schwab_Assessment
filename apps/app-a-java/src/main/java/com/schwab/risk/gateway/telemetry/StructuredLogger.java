package com.schwab.risk.gateway.telemetry;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.risk.gateway.api.model.RiskResponse;
import com.schwab.risk.gateway.client.DownstreamResult;
import com.schwab.risk.gateway.config.AppAProperties;
import java.util.Arrays;
import org.springframework.stereotype.Component;

@Component
public class StructuredLogger {

  private static final String SERVICE_NAME = "app-a-gateway";
  private static final int MAX_STACK_FRAMES = 32;

  private final ObjectMapper objectMapper;
  private final AppAProperties properties;
  private final TraceContextResolver traceContextResolver;

  public StructuredLogger(
      ObjectMapper objectMapper,
      AppAProperties properties,
      TraceContextResolver traceContextResolver) {
    this.objectMapper = objectMapper;
    this.properties = properties;
    this.traceContextResolver = traceContextResolver;
  }

  public void schemaSeed() {
    emit(createSchemaSeedEvent());
  }

  public void request(
      RequestTelemetry telemetry, int statusCode, long latencyMs, String requestMethod) {
    emit(createRequestEvent(telemetry, statusCode, latencyMs, requestMethod));
  }

  public void dependencyProbeSuccess(TraceContext traceContext, DownstreamResult result) {
    RiskResponse response = result.response();
    emit(
        event(
            "INFO",
            "dependency evaluation probe succeeded",
            "dependency_probe",
            traceContext,
            "/v1/evaluate",
            "POST",
            200,
            result.latencyMs(),
            result.latencyMs(),
            response.decision().name(),
            "",
            ""));
  }

  public void dependencyProbeFailure(
      TraceContext traceContext, int statusCode, long latencyMs, String errorType) {
    emit(
        event(
            "WARNING",
            "dependency evaluation probe failed",
            "dependency_probe",
            traceContext,
            "/v1/evaluate",
            "POST",
            statusCode,
            latencyMs,
            latencyMs,
            "",
            errorType,
            ""));
  }

  StructuredLogEvent createSchemaSeedEvent() {
    TraceContext traceContext =
        traceContextResolver.newTrace("00000000-0000-0000-0000-000000000000");
    return event(
        "INFO",
        "structured log schema initialized",
        "schema_seed",
        traceContext,
        "",
        "",
        0,
        0,
        0,
        "",
        "",
        "");
  }

  StructuredLogEvent createRequestEvent(
      RequestTelemetry telemetry, int statusCode, long latencyMs, String requestMethod) {
    String severity = statusCode >= 500 ? "ERROR" : statusCode >= 400 ? "WARNING" : "INFO";
    String message = statusCode < 400 ? "risk evaluation completed" : "risk evaluation failed";
    return event(
        severity,
        message,
        "request",
        telemetry.traceContext(),
        "/v1/risk",
        requestMethod,
        statusCode,
        latencyMs,
        telemetry.downstreamLatencyMs(),
        telemetry.decision(),
        telemetry.errorType(),
        statusCode >= 500 ? safeStackTrace(telemetry.error()) : "");
  }

  String serialize(StructuredLogEvent event) throws JsonProcessingException {
    return objectMapper.writeValueAsString(event);
  }

  private StructuredLogEvent event(
      String severity,
      String message,
      String logType,
      TraceContext traceContext,
      String route,
      String method,
      int statusCode,
      long latencyMs,
      long downstreamLatencyMs,
      String decision,
      String errorType,
      String stackTrace) {
    return new StructuredLogEvent(
        severity,
        message,
        logType,
        SERVICE_NAME,
        properties.serviceVersion(),
        properties.region(),
        properties.cluster(),
        traceContext.correlationId(),
        traceContext.traceId(),
        route,
        method,
        statusCode,
        Math.max(0, latencyMs),
        Math.max(0, downstreamLatencyMs),
        decision,
        errorType,
        stackTrace,
        false,
        googleTrace(traceContext.traceId()));
  }

  private String googleTrace(String traceId) {
    String project = properties.googleCloudProject();
    return project == null || project.isBlank() ? "" : "projects/" + project + "/traces/" + traceId;
  }

  private static String safeStackTrace(Throwable throwable) {
    if (throwable == null) {
      return "";
    }

    StringBuilder value =
        new StringBuilder(throwable.getClass().getName()).append(": request processing failed");
    Arrays.stream(throwable.getStackTrace())
        .limit(MAX_STACK_FRAMES)
        .forEach(frame -> value.append(System.lineSeparator()).append("\tat ").append(frame));
    return value.toString();
  }

  private void emit(StructuredLogEvent event) {
    try {
      System.out.println(serialize(event));
    } catch (JsonProcessingException ignored) {
      // Telemetry is deliberately outside the customer request's failure path.
    }
  }
}

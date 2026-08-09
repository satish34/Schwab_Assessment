package com.schwab.risk.gateway.telemetry;

public final class RequestTelemetry {

  public static final String ATTRIBUTE = RequestTelemetry.class.getName();

  private final TraceContext traceContext;
  private long downstreamLatencyMs;
  private String decision = "";
  private String errorType = "";
  private Throwable error;

  public RequestTelemetry(TraceContext traceContext) {
    this.traceContext = traceContext;
  }

  public TraceContext traceContext() {
    return traceContext;
  }

  public long downstreamLatencyMs() {
    return downstreamLatencyMs;
  }

  public String decision() {
    return decision;
  }

  public String errorType() {
    return errorType;
  }

  public Throwable error() {
    return error;
  }

  public void markSuccess(long latencyMs, String resultDecision) {
    this.downstreamLatencyMs = latencyMs;
    this.decision = resultDecision;
  }

  public void markFailure(String type, long latencyMs, Throwable throwable) {
    this.errorType = type;
    this.downstreamLatencyMs = latencyMs;
    this.error = throwable;
  }
}

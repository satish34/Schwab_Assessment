package com.schwab.exchange.gateway.telemetry;

public final class RequestTelemetry {

  public static final String ATTRIBUTE = RequestTelemetry.class.getName();

  private final TraceContext traceContext;
  private long downstreamLatencyMs;
  private String outcome = "";
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

  public String outcome() {
    return outcome;
  }

  public String errorType() {
    return errorType;
  }

  public Throwable error() {
    return error;
  }

  public void markSuccess(long latencyMs, String resultOutcome) {
    this.downstreamLatencyMs = latencyMs;
    this.outcome = resultOutcome;
  }

  public void markFailure(String type, long latencyMs, Throwable throwable) {
    this.errorType = type;
    this.downstreamLatencyMs = latencyMs;
    this.error = throwable;
  }
}

package com.schwab.exchange.gateway.client;

public class DependencyUnavailableException extends RuntimeException {

  private final long downstreamLatencyMs;
  private final String errorType;

  public DependencyUnavailableException(
      String errorType, long downstreamLatencyMs, Throwable cause) {
    super("Local exchange-rate dependency is unavailable", cause);
    this.errorType = errorType;
    this.downstreamLatencyMs = downstreamLatencyMs;
  }

  public long downstreamLatencyMs() {
    return downstreamLatencyMs;
  }

  public String errorType() {
    return errorType;
  }
}

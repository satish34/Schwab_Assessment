package com.schwab.risk.gateway.client;

public class DownstreamTimeoutException extends RuntimeException {

  private final long downstreamLatencyMs;

  public DownstreamTimeoutException(long downstreamLatencyMs, Throwable cause) {
    super("Local evaluation dependency timed out", cause);
    this.downstreamLatencyMs = downstreamLatencyMs;
  }

  public long downstreamLatencyMs() {
    return downstreamLatencyMs;
  }
}

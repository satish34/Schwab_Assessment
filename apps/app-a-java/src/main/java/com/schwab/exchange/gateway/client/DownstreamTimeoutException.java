package com.schwab.exchange.gateway.client;

public class DownstreamTimeoutException extends RuntimeException {

  private final long downstreamLatencyMs;

  public DownstreamTimeoutException(long downstreamLatencyMs, Throwable cause) {
    super("Local exchange-rate dependency timed out", cause);
    this.downstreamLatencyMs = downstreamLatencyMs;
  }

  public long downstreamLatencyMs() {
    return downstreamLatencyMs;
  }
}

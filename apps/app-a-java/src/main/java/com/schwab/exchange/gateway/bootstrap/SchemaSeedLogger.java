package com.schwab.exchange.gateway.bootstrap;

import com.schwab.exchange.gateway.telemetry.StructuredLogger;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
public class SchemaSeedLogger {

  private final StructuredLogger structuredLogger;

  public SchemaSeedLogger(StructuredLogger structuredLogger) {
    this.structuredLogger = structuredLogger;
  }

  @EventListener(ApplicationReadyEvent.class)
  public void emitSchemaSeed() {
    structuredLogger.schemaSeed();
  }
}

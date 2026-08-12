package com.schwab.exchange.gateway.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "exchange.telemetry")
public record TelemetryProperties(boolean enabled) {}

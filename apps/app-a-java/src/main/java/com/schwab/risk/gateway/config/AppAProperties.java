package com.schwab.risk.gateway.config;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.net.URI;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties(prefix = "risk")
public record AppAProperties(
    @NotBlank String region,
    @NotBlank String cluster,
    @NotBlank String serviceVersion,
    @NotNull URI appBBaseUrl,
    String googleCloudProject,
    @NotNull Duration connectTimeout,
    @NotNull Duration responseTimeout,
    boolean probeEnabled,
    @Min(1) long probeIntervalMs,
    @Min(1) int cellFailureThreshold,
    @Min(1) int cellRecoveryThreshold) {}

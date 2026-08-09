package com.schwab.risk.gateway.api.model;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.util.UUID;

public record RiskRequest(
    @NotNull UUID requestId,
    @NotNull @DecimalMin("0.01") @Digits(integer = 15, fraction = 2) BigDecimal amount,
    @NotBlank @Pattern(regexp = "^[A-Z]{3}$") String currency,
    @NotBlank @Size(max = 64) String merchantCategory,
    @NotBlank @Pattern(regexp = "^[A-Z]{2}$") String countryCode,
    @NotBlank @Size(max = 64) String channel) {}

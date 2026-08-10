package com.schwab.exchange.gateway.api.model;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.math.BigDecimal;

public record CurrencyRates(
    @JsonProperty("EUR") BigDecimal eur,
    @JsonProperty("GBP") BigDecimal gbp,
    @JsonProperty("JPY") BigDecimal jpy) {}

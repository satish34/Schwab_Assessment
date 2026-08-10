package com.schwab.exchange.gateway.api.model;

import java.util.List;

public record ExchangeRatesResponse(
    String baseCurrency,
    List<CurrencyRates> rateSnapshots,
    String disclaimer,
    ProvidedBy providedBy) {}

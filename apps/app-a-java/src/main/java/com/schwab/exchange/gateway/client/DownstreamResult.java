package com.schwab.exchange.gateway.client;

import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;

public record DownstreamResult(ExchangeRatesResponse response, long latencyMs) {}

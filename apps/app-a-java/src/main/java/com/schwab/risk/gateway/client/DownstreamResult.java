package com.schwab.risk.gateway.client;

import com.schwab.risk.gateway.api.model.RiskResponse;

public record DownstreamResult(RiskResponse response, long latencyMs) {}

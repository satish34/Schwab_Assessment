package com.schwab.exchange.gateway.telemetry;

public record TraceResolution(TraceContext context, boolean correlationIdValid) {}

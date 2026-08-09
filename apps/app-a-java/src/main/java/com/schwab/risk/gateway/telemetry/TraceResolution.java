package com.schwab.risk.gateway.telemetry;

public record TraceResolution(TraceContext context, boolean correlationIdValid) {}

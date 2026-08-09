package com.schwab.risk.gateway.api.model;

public record EvaluatedBy(String service, String region, String cluster, String version) {}

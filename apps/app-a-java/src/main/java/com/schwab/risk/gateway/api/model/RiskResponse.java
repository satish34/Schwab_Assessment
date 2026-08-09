package com.schwab.risk.gateway.api.model;

import java.util.List;
import java.util.UUID;

public record RiskResponse(
    UUID requestId,
    Integer score,
    Decision decision,
    List<String> rulesFired,
    EvaluatedBy evaluatedBy) {}

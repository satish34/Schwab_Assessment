package com.schwab.risk.gateway.api;

import com.schwab.risk.gateway.api.model.RiskRequest;
import com.schwab.risk.gateway.api.model.RiskResponse;
import com.schwab.risk.gateway.client.AppBClient;
import com.schwab.risk.gateway.client.DownstreamResult;
import com.schwab.risk.gateway.telemetry.RequestTelemetry;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1")
public class RiskController {

  private final AppBClient appBClient;

  public RiskController(AppBClient appBClient) {
    this.appBClient = appBClient;
  }

  @PostMapping("/risk")
  public ResponseEntity<RiskResponse> evaluate(
      @Valid @RequestBody RiskRequest request, HttpServletRequest servletRequest) {
    RequestTelemetry telemetry = telemetry(servletRequest);
    DownstreamResult result = appBClient.evaluate(request, telemetry.traceContext(), false);
    telemetry.markSuccess(result.latencyMs(), result.response().decision().name());
    return ResponseEntity.ok(result.response());
  }

  private static RequestTelemetry telemetry(HttpServletRequest request) {
    return (RequestTelemetry) request.getAttribute(RequestTelemetry.ATTRIBUTE);
  }
}

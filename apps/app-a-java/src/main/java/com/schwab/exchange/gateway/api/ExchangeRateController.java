package com.schwab.exchange.gateway.api;

import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;
import com.schwab.exchange.gateway.client.AppBClient;
import com.schwab.exchange.gateway.client.DownstreamResult;
import com.schwab.exchange.gateway.telemetry.RequestTelemetry;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class ExchangeRateController {

  private final AppBClient appBClient;

  public ExchangeRateController(AppBClient appBClient) {
    this.appBClient = appBClient;
  }

  @GetMapping("/exchange-rates")
  public ResponseEntity<ExchangeRatesResponse> getExchangeRates(HttpServletRequest servletRequest) {
    RequestTelemetry telemetry = telemetry(servletRequest);
    DownstreamResult result = appBClient.getExchangeRates(telemetry.traceContext(), false);
    telemetry.markSuccess(result.latencyMs(), "RATES_RETURNED");
    return ResponseEntity.ok(result.response());
  }

  private static RequestTelemetry telemetry(HttpServletRequest request) {
    return (RequestTelemetry) request.getAttribute(RequestTelemetry.ATTRIBUTE);
  }
}

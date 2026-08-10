package com.schwab.exchange.gateway.api;

import com.schwab.exchange.gateway.api.model.HealthResponse;
import com.schwab.exchange.gateway.health.CellHealthState;
import com.schwab.exchange.gateway.health.CellHealthStatus;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/health")
public class HealthController {

  private final CellHealthState cellHealthState;

  public HealthController(CellHealthState cellHealthState) {
    this.cellHealthState = cellHealthState;
  }

  @GetMapping("/live")
  public HealthResponse live() {
    return new HealthResponse("UP");
  }

  @GetMapping("/ready")
  public HealthResponse ready() {
    return new HealthResponse("UP");
  }

  @GetMapping("/cell")
  public ResponseEntity<HealthResponse> cell() {
    CellHealthState.Snapshot snapshot = cellHealthState.current();
    HttpStatus status =
        snapshot.status() == CellHealthStatus.HEALTHY
            ? HttpStatus.OK
            : HttpStatus.SERVICE_UNAVAILABLE;
    return ResponseEntity.status(status).body(new HealthResponse(snapshot.status().name()));
  }
}

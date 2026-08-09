package com.schwab.risk.gateway.api;

import static org.assertj.core.api.Assertions.assertThat;

import com.schwab.risk.gateway.health.CellHealthState;
import com.schwab.risk.gateway.health.CellHealthStatus;
import org.junit.jupiter.api.Test;

class HealthControllerTest {

  @Test
  void livenessAndReadinessAreIndependentFromCellHealth() {
    CellHealthState state = CellHealthState.withThresholds(3, 5);
    HealthController controller = new HealthController(state);

    assertThat(controller.live().status()).isEqualTo("UP");
    assertThat(controller.ready().status()).isEqualTo("UP");
    assertThat(controller.cell().getStatusCode().value()).isEqualTo(503);
    assertThat(controller.cell().getBody().status()).isEqualTo(CellHealthStatus.UNKNOWN.name());
  }
}

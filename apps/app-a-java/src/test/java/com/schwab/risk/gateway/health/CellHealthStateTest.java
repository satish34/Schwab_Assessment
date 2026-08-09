package com.schwab.risk.gateway.health;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class CellHealthStateTest {

  private final CellHealthState state = CellHealthState.withThresholds(3, 5);

  @Test
  void failsFastAndRecoversWithSlowerHysteresis() {
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.UNKNOWN);
    assertThat(state.isServing()).isFalse();

    recordSuccesses(4);
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.UNKNOWN);

    state.recordSuccess();
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.HEALTHY);

    state.recordFailure();
    state.recordFailure();
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.HEALTHY);

    state.recordFailure();
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.UNHEALTHY);
    assertThat(state.isServing()).isFalse();

    recordSuccesses(4);
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.UNHEALTHY);

    state.recordSuccess();
    assertThat(state.current().status()).isEqualTo(CellHealthStatus.HEALTHY);
    assertThat(state.isServing()).isTrue();
  }

  @Test
  void anyOppositeResultResetsTheConsecutiveCounter() {
    state.recordSuccess();
    state.recordSuccess();
    state.recordFailure();
    assertThat(state.current().consecutiveSuccesses()).isZero();

    state.recordFailure();
    state.recordSuccess();
    assertThat(state.current().consecutiveFailures()).isZero();
    assertThat(state.current().consecutiveSuccesses()).isEqualTo(1);
  }

  private void recordSuccesses(int count) {
    for (int success = 0; success < count; success++) {
      state.recordSuccess();
    }
  }
}

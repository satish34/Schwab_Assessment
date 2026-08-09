package com.schwab.risk.gateway.health;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.scheduling.annotation.Scheduled;

class CellHealthProberSchedulingTest {

  @Test
  void startsProbesAtTheConfiguredCadenceInsteadOfWaitingForPriorCompletion() throws Exception {
    Scheduled schedule = CellHealthProber.class.getMethod("probe").getAnnotation(Scheduled.class);

    assertThat(schedule.fixedRateString()).isEqualTo("${risk.probe-interval-ms:2000}");
    assertThat(schedule.fixedDelayString()).isEmpty();
    assertThat(schedule.initialDelayString()).isEqualTo("${risk.probe-interval-ms:2000}");
  }
}

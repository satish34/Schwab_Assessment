package com.schwab.exchange.gateway.health;

import com.schwab.exchange.gateway.config.AppAProperties;
import java.util.concurrent.atomic.AtomicReference;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

@Component
public class CellHealthState {

  private final int failureThreshold;
  private final int recoveryThreshold;
  private final AtomicReference<Snapshot> snapshot =
      new AtomicReference<>(new Snapshot(CellHealthStatus.UNKNOWN, 0, 0));

  @Autowired
  public CellHealthState(AppAProperties properties) {
    this(properties.cellFailureThreshold(), properties.cellRecoveryThreshold());
  }

  private CellHealthState(int failureThreshold, int recoveryThreshold) {
    this.failureThreshold = failureThreshold;
    this.recoveryThreshold = recoveryThreshold;
  }

  public static CellHealthState withThresholds(int failureThreshold, int recoveryThreshold) {
    return new CellHealthState(failureThreshold, recoveryThreshold);
  }

  public void recordSuccess() {
    snapshot.updateAndGet(
        current -> {
          if (current.status() == CellHealthStatus.HEALTHY) {
            return new Snapshot(CellHealthStatus.HEALTHY, recoveryThreshold, 0);
          }
          int successes = Math.min(recoveryThreshold, current.consecutiveSuccesses() + 1);
          CellHealthStatus next =
              successes >= recoveryThreshold ? CellHealthStatus.HEALTHY : current.status();
          return new Snapshot(next, successes, 0);
        });
  }

  public void recordFailure() {
    snapshot.updateAndGet(
        current -> {
          int failures = Math.min(failureThreshold, current.consecutiveFailures() + 1);
          CellHealthStatus next =
              failures >= failureThreshold ? CellHealthStatus.UNHEALTHY : current.status();
          return new Snapshot(next, 0, failures);
        });
  }

  public Snapshot current() {
    return snapshot.get();
  }

  public boolean isServing() {
    return snapshot.get().status() == CellHealthStatus.HEALTHY;
  }

  public record Snapshot(
      CellHealthStatus status, int consecutiveSuccesses, int consecutiveFailures) {}
}

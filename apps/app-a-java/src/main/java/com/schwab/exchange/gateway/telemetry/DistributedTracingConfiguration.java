package com.schwab.exchange.gateway.telemetry;

import com.schwab.exchange.gateway.config.AppAProperties;
import com.schwab.exchange.gateway.config.TelemetryProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration(proxyBeanMethods = false)
public class DistributedTracingConfiguration {

  @Bean(destroyMethod = "close")
  DistributedTracing distributedTracing(
      TelemetryProperties telemetryProperties, AppAProperties appAProperties) {
    return DistributedTracing.create(telemetryProperties, appAProperties);
  }
}

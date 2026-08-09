package com.schwab.risk.gateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

@EnableScheduling
@ConfigurationPropertiesScan
@SpringBootApplication
public class AppAGatewayApplication {

  public static void main(String[] args) {
    SpringApplication.run(AppAGatewayApplication.class, args);
  }
}

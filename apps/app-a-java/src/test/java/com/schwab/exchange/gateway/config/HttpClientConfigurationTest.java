package com.schwab.exchange.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.exchange.gateway.auth.AppBIdentityTokenProvider;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;
import org.springframework.web.client.RestClient;

class HttpClientConfigurationTest {

  private final ApplicationContextRunner contextRunner =
      new ApplicationContextRunner()
          .withUserConfiguration(TestConfiguration.class)
          .withPropertyValues(
              "exchange.region=local",
              "exchange.cluster=local-test",
              "exchange.service-version=test",
              "exchange.app-b-base-url=http://app-b-engine:8080",
              "exchange.app-b-token-audience=https://app-b-engine.schwab-assessment.internal",
              "exchange.google-cloud-project=test-project",
              "exchange.connect-timeout=500ms",
              "exchange.response-timeout=750ms",
              "exchange.metadata-timeout=3s",
              "exchange.probe-enabled=false",
              "exchange.probe-interval-ms=2000",
              "exchange.cell-failure-threshold=3",
              "exchange.cell-recovery-threshold=5");

  @Test
  void disabledModeFailsStartupWithoutAnExplicitLocalOrTestProfile() {
    contextRunner
        .withPropertyValues("exchange.app-b-auth-mode=disabled")
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasRootCauseMessage(
                      "APP_B_AUTH_MODE=disabled requires the local or test Spring profile");
            });
  }

  @Test
  void disabledModeStartsOnlyUnderTheExplicitLocalProfile() {
    contextRunner
        .withPropertyValues("exchange.app-b-auth-mode=disabled", "spring.profiles.active=local")
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              AppBIdentityTokenProvider provider = context.getBean(AppBIdentityTokenProvider.class);
              assertThat(provider.authenticationRequired()).isFalse();
              assertThat(provider.identityToken()).isEmpty();
              assertThat(context.getBean(AppAProperties.class).metadataTimeout())
                  .isEqualTo(Duration.ofSeconds(3));
            });
  }

  @Test
  void disabledModeStartsUnderTheExplicitTestProfile() {
    contextRunner
        .withPropertyValues("exchange.app-b-auth-mode=disabled", "spring.profiles.active=test")
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              assertThat(context.getBean(AppBIdentityTokenProvider.class).authenticationRequired())
                  .isFalse();
            });
  }

  @Test
  void googleModeRemainsFailClosedWithoutALocalProfile() {
    contextRunner
        .withPropertyValues("exchange.app-b-auth-mode=google-id-token")
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              assertThat(context.getBean(AppBIdentityTokenProvider.class).authenticationRequired())
                  .isTrue();
            });
  }

  @Configuration(proxyBeanMethods = false)
  @EnableConfigurationProperties(AppAProperties.class)
  @Import(HttpClientConfiguration.class)
  static class TestConfiguration {

    @Bean
    ObjectMapper objectMapper() {
      return new ObjectMapper();
    }

    @Bean
    RestClient.Builder restClientBuilder() {
      return RestClient.builder();
    }
  }
}

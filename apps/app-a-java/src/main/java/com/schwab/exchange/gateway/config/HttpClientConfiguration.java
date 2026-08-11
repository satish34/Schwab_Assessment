package com.schwab.exchange.gateway.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.exchange.gateway.auth.AppBIdentityTokenProvider;
import com.schwab.exchange.gateway.auth.DisabledAppBIdentityTokenProvider;
import com.schwab.exchange.gateway.auth.GoogleMetadataIdentityTokenProvider;
import java.net.http.HttpClient;
import java.util.Arrays;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@Configuration
public class HttpClientConfiguration {

  @Bean
  RestClient appBRestClient(RestClient.Builder builder, AppAProperties properties) {
    HttpClient httpClient =
        HttpClient.newBuilder()
            .connectTimeout(properties.connectTimeout())
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
    requestFactory.setReadTimeout(properties.responseTimeout());

    return builder
        .baseUrl(properties.appBBaseUrl().toString())
        .requestFactory(requestFactory)
        .build();
  }

  @Bean
  AppBIdentityTokenProvider appBIdentityTokenProvider(
      AppAProperties properties, ObjectMapper objectMapper, Environment environment) {
    if (properties.appBAuthMode() == AppBAuthMode.DISABLED) {
      boolean localComposeOrTestProfile =
          Arrays.stream(environment.getActiveProfiles())
              .anyMatch(profile -> profile.equals("local-compose") || profile.equals("test"));
      if (!localComposeOrTestProfile) {
        throw new IllegalStateException(
            "APP_B_AUTH_MODE=disabled requires the local-compose or test Spring profile");
      }
      return DisabledAppBIdentityTokenProvider.INSTANCE;
    }

    HttpClient httpClient =
        HttpClient.newBuilder()
            .connectTimeout(properties.metadataTimeout())
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();
    JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
    requestFactory.setReadTimeout(properties.metadataTimeout());
    RestClient metadataRestClient =
        RestClient.builder()
            .baseUrl(GoogleMetadataIdentityTokenProvider.METADATA_IDENTITY_ENDPOINT)
            .requestFactory(requestFactory)
            .build();

    return new GoogleMetadataIdentityTokenProvider(
        metadataRestClient, objectMapper, properties.appBTokenAudience());
  }
}

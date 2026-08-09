package com.schwab.risk.gateway.config;

import java.net.http.HttpClient;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
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
}

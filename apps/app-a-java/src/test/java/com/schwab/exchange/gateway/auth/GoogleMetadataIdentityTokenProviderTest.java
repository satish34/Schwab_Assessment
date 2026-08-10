package com.schwab.exchange.gateway.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.ExpectedCount.once;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;
import org.springframework.web.util.UriComponentsBuilder;

class GoogleMetadataIdentityTokenProviderTest {

  private static final String AUDIENCE = "https://app-b-engine.schwab-assessment.internal";
  private static final Instant START = Instant.parse("2026-08-10T12:00:00Z");

  private MockRestServiceServer server;
  private MutableClock clock;
  private List<Duration> retryBackoffs;
  private GoogleMetadataIdentityTokenProvider provider;

  @BeforeEach
  void setUp() {
    RestClient.Builder builder =
        RestClient.builder()
            .baseUrl(GoogleMetadataIdentityTokenProvider.METADATA_IDENTITY_ENDPOINT);
    server = MockRestServiceServer.bindTo(builder).build();
    clock = new MutableClock(START);
    retryBackoffs = new ArrayList<>();
    provider =
        new GoogleMetadataIdentityTokenProvider(
            builder.build(), new ObjectMapper(), AUDIENCE, clock, retryBackoffs::add);
  }

  @Test
  void requestsAnAudienceBoundFullTokenWithTheMetadataHeader() {
    String token = token(AUDIENCE, START.plusSeconds(3600), "first-signature");
    expectMetadataRequest(token);

    Optional<String> result = provider.identityToken();

    assertThat(result).contains(token);
    server.verify();
  }

  @Test
  void retriesOneTransientMetadataFailureWithTheBoundedBackoff() {
    String token = token(AUDIENCE, START.plusSeconds(3600), "retry-signature");
    server
        .expect(once(), request -> {})
        .andExpect(header("Metadata-Flavor", "Google"))
        .andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));
    expectMetadataRequest(token);

    assertThat(provider.identityToken()).contains(token);
    assertThat(retryBackoffs).containsExactly(GoogleMetadataIdentityTokenProvider.RETRY_BACKOFF);
    server.verify();
  }

  @Test
  void cachesTheTokenAndRefreshesAtThreeMinutesFortyFiveSecondsBeforeExpiry() {
    String first = token(AUDIENCE, START.plusSeconds(3600), "first-signature");
    String refreshed = token(AUDIENCE, START.plusSeconds(6975), "second-signature");
    expectMetadataRequest(first);
    expectMetadataRequest(refreshed);

    assertThat(provider.identityToken()).contains(first);

    clock.advanceSeconds(3374);
    assertThat(provider.identityToken()).contains(first);

    clock.advanceSeconds(1);
    assertThat(provider.identityToken()).contains(refreshed);
    server.verify();
  }

  @Test
  void rejectsAMalformedTokenWithoutLeakingTheResponse() {
    String sensitiveResponse = "not-a-jwt-containing-sensitive-token-material";
    server
        .expect(once(), request -> {})
        .andRespond(withSuccess(sensitiveResponse, MediaType.TEXT_PLAIN));

    assertThatThrownBy(provider::identityToken)
        .isInstanceOf(IdentityTokenUnavailableException.class)
        .hasMessage("Google identity token is unavailable")
        .satisfies(
            exception -> assertThat(stackTrace(exception)).doesNotContain(sensitiveResponse));
    server.verify();
  }

  @Test
  void rejectsMetadataFailuresWithoutLeakingTheResponseBody() {
    String sensitiveResponse = "sensitive-token-material-from-failed-response";
    server
        .expect(org.springframework.test.web.client.ExpectedCount.times(2), request -> {})
        .andRespond(
            withStatus(HttpStatus.SERVICE_UNAVAILABLE)
                .contentType(MediaType.TEXT_PLAIN)
                .body(sensitiveResponse));

    assertThatThrownBy(provider::identityToken)
        .isInstanceOf(IdentityTokenUnavailableException.class)
        .satisfies(
            exception -> assertThat(stackTrace(exception)).doesNotContain(sensitiveResponse));
    assertThat(retryBackoffs).containsExactly(GoogleMetadataIdentityTokenProvider.RETRY_BACKOFF);
    server.verify();
  }

  @Test
  void rejectsATokenForADifferentAudience() {
    server
        .expect(once(), request -> {})
        .andRespond(
            withSuccess(
                token("https://another-service.invalid", START.plusSeconds(3600), "signature"),
                MediaType.TEXT_PLAIN));

    assertThatThrownBy(provider::identityToken)
        .isInstanceOf(IdentityTokenUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsAFractionalExpiryClaim() {
    String token =
        tokenWithClaims(
            "{\"iss\":\"https://accounts.google.com\",\"aud\":\""
                + AUDIENCE
                + "\",\"exp\":"
                + (START.getEpochSecond() + 3600)
                + ".5}",
            "signature");
    server.expect(once(), request -> {}).andRespond(withSuccess(token, MediaType.TEXT_PLAIN));

    assertThatThrownBy(provider::identityToken)
        .isInstanceOf(IdentityTokenUnavailableException.class);
    server.verify();
  }

  @Test
  void rejectsAnOversizedTokenWithoutLeakingIt() {
    String oversized = "a".repeat(GoogleMetadataIdentityTokenProvider.MAX_TOKEN_LENGTH + 1);
    server.expect(once(), request -> {}).andRespond(withSuccess(oversized, MediaType.TEXT_PLAIN));

    assertThatThrownBy(provider::identityToken)
        .isInstanceOf(IdentityTokenUnavailableException.class)
        .satisfies(exception -> assertThat(stackTrace(exception)).doesNotContain(oversized));
    server.verify();
  }

  @Test
  void concurrentColdCacheRequestsShareOneMetadataLookup() throws Exception {
    String token = token(AUDIENCE, START.plusSeconds(3600), "concurrent-signature");
    expectMetadataRequest(token);
    ExecutorService executor = Executors.newFixedThreadPool(8);
    try {
      List<Callable<Optional<String>>> calls =
          java.util.stream.IntStream.range(0, 16)
              .mapToObj(ignored -> (Callable<Optional<String>>) provider::identityToken)
              .toList();

      List<Future<Optional<String>>> results = executor.invokeAll(calls);

      for (Future<Optional<String>> result : results) {
        assertThat(result.get()).contains(token);
      }
    } finally {
      executor.shutdownNow();
    }
    server.verify();
  }

  @Test
  void refreshBoundaryFailsClosedWhenBothRefreshAttemptsFail() {
    String first = token(AUDIENCE, START.plusSeconds(3600), "first-signature");
    expectMetadataRequest(first);
    server
        .expect(org.springframework.test.web.client.ExpectedCount.times(2), request -> {})
        .andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));
    assertThat(provider.identityToken()).contains(first);

    clock.advanceSeconds(3375);

    assertThatThrownBy(provider::identityToken)
        .isInstanceOf(IdentityTokenUnavailableException.class);
    assertThat(retryBackoffs).containsExactly(GoogleMetadataIdentityTokenProvider.RETRY_BACKOFF);
    server.verify();
  }

  private void expectMetadataRequest(String responseToken) {
    server
        .expect(
            once(),
            request -> {
              assertThat(request.getURI().getScheme()).isEqualTo("http");
              assertThat(request.getURI().getHost()).isEqualTo("metadata.google.internal");
              assertThat(request.getURI().getPath())
                  .isEqualTo("/computeMetadata/v1/instance/service-accounts/default/identity");
              var query = UriComponentsBuilder.fromUri(request.getURI()).build().getQueryParams();
              assertThat(query.getFirst("audience")).isEqualTo(AUDIENCE);
              assertThat(query.getFirst("format")).isEqualTo("full");
              assertThat(query).hasSize(2);
            })
        .andExpect(method(HttpMethod.GET))
        .andExpect(header("Metadata-Flavor", "Google"))
        .andRespond(withSuccess(responseToken, MediaType.TEXT_PLAIN));
  }

  private static String token(String audience, Instant expiry, String signature) {
    return tokenWithClaims(
        "{\"iss\":\"https://accounts.google.com\",\"aud\":\""
            + audience
            + "\",\"exp\":"
            + expiry.getEpochSecond()
            + "}",
        signature);
  }

  private static String tokenWithClaims(String claims, String signature) {
    String header = base64Url("{\"alg\":\"RS256\",\"kid\":\"test-key\"}");
    return header + "." + base64Url(claims) + "." + base64Url(signature);
  }

  private static String base64Url(String value) {
    return Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(value.getBytes(StandardCharsets.UTF_8));
  }

  private static String stackTrace(Throwable throwable) {
    StringWriter output = new StringWriter();
    throwable.printStackTrace(new PrintWriter(output));
    return output.toString();
  }

  private static final class MutableClock extends Clock {

    private Instant instant;

    private MutableClock(Instant instant) {
      this.instant = instant;
    }

    private void advanceSeconds(long seconds) {
      instant = instant.plusSeconds(seconds);
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
      return this;
    }

    @Override
    public Instant instant() {
      return instant;
    }
  }
}

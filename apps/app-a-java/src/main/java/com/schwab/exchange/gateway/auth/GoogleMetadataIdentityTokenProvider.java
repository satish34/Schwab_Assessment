package com.schwab.exchange.gateway.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Optional;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

public final class GoogleMetadataIdentityTokenProvider implements AppBIdentityTokenProvider {

  public static final String METADATA_IDENTITY_ENDPOINT =
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity";
  static final Duration REFRESH_BEFORE_EXPIRY = Duration.ofMinutes(3).plusSeconds(45);
  static final Duration RETRY_BACKOFF = Duration.ofMillis(100);
  static final int MAX_METADATA_ATTEMPTS = 2;

  static final int MAX_TOKEN_LENGTH = 16_384;
  private static final int MAX_HEADER_LENGTH = 2_048;
  private static final int MAX_CLAIMS_LENGTH = 8_192;
  private static final int MAX_SIGNATURE_LENGTH = 2_048;

  private final RestClient metadataRestClient;
  private final ObjectMapper objectMapper;
  private final String audience;
  private final Clock clock;
  private final RetrySleeper retrySleeper;
  private final Object refreshLock = new Object();

  private volatile CachedToken cachedToken;

  public GoogleMetadataIdentityTokenProvider(
      RestClient metadataRestClient, ObjectMapper objectMapper, String audience) {
    this(
        metadataRestClient,
        objectMapper,
        audience,
        Clock.systemUTC(),
        duration -> Thread.sleep(duration.toMillis()));
  }

  GoogleMetadataIdentityTokenProvider(
      RestClient metadataRestClient, ObjectMapper objectMapper, String audience, Clock clock) {
    this(
        metadataRestClient,
        objectMapper,
        audience,
        clock,
        duration -> Thread.sleep(duration.toMillis()));
  }

  GoogleMetadataIdentityTokenProvider(
      RestClient metadataRestClient,
      ObjectMapper objectMapper,
      String audience,
      Clock clock,
      RetrySleeper retrySleeper) {
    this.metadataRestClient = metadataRestClient;
    this.objectMapper = objectMapper;
    this.audience = audience;
    this.clock = clock;
    this.retrySleeper = retrySleeper;
  }

  @Override
  public Optional<String> identityToken() {
    Instant now = clock.instant();
    CachedToken current = cachedToken;
    if (isReusable(current, now)) {
      return Optional.of(current.value());
    }

    synchronized (refreshLock) {
      now = clock.instant();
      current = cachedToken;
      if (isReusable(current, now)) {
        return Optional.of(current.value());
      }

      CachedToken refreshed = retrieveToken(now);
      cachedToken = refreshed;
      return Optional.of(refreshed.value());
    }
  }

  private CachedToken retrieveToken(Instant now) {
    String response = retrieveResponseWithRetry();

    try {
      String token = normalizeToken(response);
      JsonNode claims = validateStructureAndDecodeClaims(token);
      JsonNode expiryClaim = claims.get("exp");
      JsonNode audienceClaim = claims.get("aud");
      if (expiryClaim == null
          || !expiryClaim.isIntegralNumber()
          || !expiryClaim.canConvertToLong()
          || audienceClaim == null
          || !audienceClaim.isTextual()
          || !audience.equals(audienceClaim.textValue())) {
        throw new IdentityTokenUnavailableException();
      }

      Instant expiry = Instant.ofEpochSecond(expiryClaim.longValue());
      if (!expiry.minus(REFRESH_BEFORE_EXPIRY).isAfter(now)) {
        throw new IdentityTokenUnavailableException();
      }
      return new CachedToken(token, expiry);
    } catch (IdentityTokenUnavailableException exception) {
      throw exception;
    } catch (RuntimeException exception) {
      throw new IdentityTokenUnavailableException();
    }
  }

  private String retrieveResponseWithRetry() {
    for (int attempt = 1; attempt <= MAX_METADATA_ATTEMPTS; attempt++) {
      try {
        return metadataRestClient
            .get()
            .uri(
                uriBuilder ->
                    uriBuilder
                        .queryParam("audience", audience)
                        .queryParam("format", "full")
                        .build())
            .header("Metadata-Flavor", "Google")
            .retrieve()
            .body(String.class);
      } catch (RestClientException exception) {
        if (attempt == MAX_METADATA_ATTEMPTS) {
          throw new IdentityTokenUnavailableException();
        }
        try {
          retrySleeper.sleep(RETRY_BACKOFF);
        } catch (InterruptedException interruptedException) {
          Thread.currentThread().interrupt();
          throw new IdentityTokenUnavailableException();
        }
      }
    }
    throw new IdentityTokenUnavailableException();
  }

  private JsonNode validateStructureAndDecodeClaims(String token) {
    String[] segments = token.split("\\.", -1);
    if (segments.length != 3
        || segments[0].isEmpty()
        || segments[1].isEmpty()
        || segments[2].isEmpty()) {
      throw new IdentityTokenUnavailableException();
    }

    JsonNode header = decodeJsonSegment(segments[0], MAX_HEADER_LENGTH);
    if (!header.isObject()
        || !"RS256".equals(header.path("alg").textValue())
        || !header.path("kid").isTextual()
        || header.path("kid").textValue().isBlank()) {
      throw new IdentityTokenUnavailableException();
    }

    JsonNode claims = decodeJsonSegment(segments[1], MAX_CLAIMS_LENGTH);
    byte[] signature = decodeBase64UrlSegment(segments[2], MAX_SIGNATURE_LENGTH);
    if (!claims.isObject() || signature.length == 0) {
      throw new IdentityTokenUnavailableException();
    }
    return claims;
  }

  private JsonNode decodeJsonSegment(String segment, int maximumDecodedLength) {
    byte[] decoded = decodeBase64UrlSegment(segment, maximumDecodedLength);
    try {
      return objectMapper.readTree(new String(decoded, StandardCharsets.UTF_8));
    } catch (Exception exception) {
      throw new IdentityTokenUnavailableException();
    }
  }

  private static byte[] decodeBase64UrlSegment(String segment, int maximumDecodedLength) {
    if (!isUnpaddedBase64Url(segment)) {
      throw new IdentityTokenUnavailableException();
    }
    byte[] decoded = Base64.getUrlDecoder().decode(segment);
    if (decoded.length == 0 || decoded.length > maximumDecodedLength) {
      throw new IdentityTokenUnavailableException();
    }
    return decoded;
  }

  private static boolean isUnpaddedBase64Url(String value) {
    for (int index = 0; index < value.length(); index++) {
      char character = value.charAt(index);
      if (!(character >= 'A' && character <= 'Z')
          && !(character >= 'a' && character <= 'z')
          && !(character >= '0' && character <= '9')
          && character != '-'
          && character != '_') {
        return false;
      }
    }
    return !value.isEmpty();
  }

  private static String normalizeToken(String response) {
    if (response == null) {
      throw new IdentityTokenUnavailableException();
    }
    String token = response.trim();
    if (token.isEmpty()
        || token.length() > MAX_TOKEN_LENGTH
        || token.chars().anyMatch(Character::isWhitespace)) {
      throw new IdentityTokenUnavailableException();
    }
    return token;
  }

  private static boolean isReusable(CachedToken token, Instant now) {
    return token != null && token.expiresAt().minus(REFRESH_BEFORE_EXPIRY).isAfter(now);
  }

  private record CachedToken(String value, Instant expiresAt) {}

  @FunctionalInterface
  interface RetrySleeper {
    void sleep(Duration duration) throws InterruptedException;
  }
}

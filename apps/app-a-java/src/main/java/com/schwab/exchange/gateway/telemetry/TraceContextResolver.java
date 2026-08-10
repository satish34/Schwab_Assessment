package com.schwab.exchange.gateway.telemetry;

import java.security.SecureRandom;
import java.util.HexFormat;
import java.util.Locale;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.stereotype.Component;

@Component
public class TraceContextResolver {

  private static final Pattern TRACEPARENT_PATTERN =
      Pattern.compile("^00-([0-9a-fA-F]{32})-([0-9a-fA-F]{16})-([0-9a-fA-F]{2})$");
  private static final String ZERO_TRACE_ID = "00000000000000000000000000000000";
  private static final String ZERO_SPAN_ID = "0000000000000000";
  private static final SecureRandom RANDOM = new SecureRandom();

  public TraceResolution resolve(String correlationHeader, String traceparentHeader) {
    CorrelationResolution correlation = resolveCorrelation(correlationHeader);
    return new TraceResolution(
        resolveTrace(correlation.value(), traceparentHeader), correlation.valid());
  }

  public TraceContext newTrace(String correlationId) {
    return resolveTrace(correlationId, null);
  }

  private static CorrelationResolution resolveCorrelation(String header) {
    if (header == null || header.isBlank()) {
      return new CorrelationResolution(UUID.randomUUID().toString(), true);
    }

    String candidate = header.trim();
    try {
      String canonical = UUID.fromString(candidate).toString();
      boolean valid = canonical.equalsIgnoreCase(candidate);
      return new CorrelationResolution(valid ? canonical : UUID.randomUUID().toString(), valid);
    } catch (IllegalArgumentException ignored) {
      return new CorrelationResolution(UUID.randomUUID().toString(), false);
    }
  }

  private static TraceContext resolveTrace(String correlationId, String header) {
    if (header != null) {
      Matcher matcher = TRACEPARENT_PATTERN.matcher(header.trim());
      if (matcher.matches()
          && !ZERO_TRACE_ID.equals(matcher.group(1))
          && !ZERO_SPAN_ID.equals(matcher.group(2))) {
        String normalized = header.trim().toLowerCase(Locale.ROOT);
        return new TraceContext(
            correlationId, matcher.group(1).toLowerCase(Locale.ROOT), normalized);
      }
    }

    String traceId = randomHex(16);
    String spanId = randomHex(8);
    return new TraceContext(correlationId, traceId, "00-" + traceId + "-" + spanId + "-01");
  }

  private static String randomHex(int bytes) {
    byte[] value = new byte[bytes];
    RANDOM.nextBytes(value);
    return HexFormat.of().formatHex(value);
  }

  private record CorrelationResolution(String value, boolean valid) {}
}

package com.schwab.risk.gateway.telemetry;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.risk.gateway.api.model.ErrorResponse;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.InvalidMediaTypeException;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class RiskRequestContextFilter extends OncePerRequestFilter {

  private final TraceContextResolver traceContextResolver;
  private final StructuredLogger structuredLogger;
  private final ObjectMapper objectMapper;

  public RiskRequestContextFilter(
      TraceContextResolver traceContextResolver,
      StructuredLogger structuredLogger,
      ObjectMapper objectMapper) {
    this.traceContextResolver = traceContextResolver;
    this.structuredLogger = structuredLogger;
    this.objectMapper = objectMapper;
  }

  @Override
  protected boolean shouldNotFilter(HttpServletRequest request) {
    return !"/v1/risk".equals(request.getRequestURI());
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
      throws ServletException, IOException {
    long startedAt = System.nanoTime();
    TraceResolution resolution =
        traceContextResolver.resolve(
            request.getHeader("x-correlation-id"), request.getHeader("traceparent"));
    RequestTelemetry telemetry = new RequestTelemetry(resolution.context());
    request.setAttribute(RequestTelemetry.ATTRIBUTE, telemetry);
    response.setHeader("x-correlation-id", resolution.context().correlationId());
    response.setHeader("traceparent", resolution.context().traceparent());

    try {
      if (!acceptsJson(request)) {
        telemetry.markFailure("validation_error", 0, null);
        response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
        return;
      }

      if (!resolution.correlationIdValid()) {
        telemetry.markFailure("validation_error", 0, null);
        response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        objectMapper.writeValue(
            response.getOutputStream(),
            new ErrorResponse("VALIDATION_ERROR", "Request validation failed"));
        return;
      }

      filterChain.doFilter(request, response);
    } catch (IOException | ServletException | RuntimeException exception) {
      telemetry.markFailure("internal_error", telemetry.downstreamLatencyMs(), exception);
      if (!response.isCommitted()) {
        response.setStatus(HttpServletResponse.SC_SERVICE_UNAVAILABLE);
      }
      throw exception;
    } finally {
      structuredLogger.request(
          telemetry, response.getStatus(), elapsedMillis(startedAt), request.getMethod());
    }
  }

  private static long elapsedMillis(long startedAt) {
    return Math.max(0, TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt));
  }

  private static boolean acceptsJson(HttpServletRequest request) {
    String accept = request.getHeader("Accept");
    if (accept == null || accept.isBlank()) {
      return true;
    }
    try {
      List<MediaType> acceptedTypes = MediaType.parseMediaTypes(accept);
      return acceptedTypes.stream()
          .anyMatch(
              mediaType ->
                  mediaType.getQualityValue() > 0
                      && mediaType.isCompatibleWith(MediaType.APPLICATION_JSON));
    } catch (InvalidMediaTypeException exception) {
      return false;
    }
  }
}

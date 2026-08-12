package com.schwab.exchange.gateway.telemetry;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.exchange.gateway.api.model.ErrorResponse;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpHeaders;
import org.springframework.http.InvalidMediaTypeException;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class ExchangeRateRequestContextFilter extends OncePerRequestFilter {

  static final String API_PATH = "/api/exchange-rates";
  private static final ErrorResponse VALIDATION_ERROR =
      new ErrorResponse("VALIDATION_ERROR", "Request validation failed");

  private final TraceContextResolver traceContextResolver;
  private final DistributedTracing distributedTracing;
  private final StructuredLogger structuredLogger;
  private final ObjectMapper objectMapper;

  public ExchangeRateRequestContextFilter(
      TraceContextResolver traceContextResolver,
      DistributedTracing distributedTracing,
      StructuredLogger structuredLogger,
      ObjectMapper objectMapper) {
    this.traceContextResolver = traceContextResolver;
    this.distributedTracing = distributedTracing;
    this.structuredLogger = structuredLogger;
    this.objectMapper = objectMapper;
  }

  @Override
  protected boolean shouldNotFilter(HttpServletRequest request) {
    return !API_PATH.equals(request.getRequestURI());
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
      throws ServletException, IOException {
    long startedAt = System.nanoTime();
    TraceResolution resolution =
        traceContextResolver.resolve(
            request.getHeader("x-correlation-id"),
            request.getHeader("traceparent"),
            request.getHeader("tracestate"));

    try (DistributedTracing.TraceSpan serverSpan =
        distributedTracing.startServerSpan(resolution, request.getMethod(), API_PATH)) {
      RequestTelemetry telemetry = new RequestTelemetry(serverSpan.traceContext());
      request.setAttribute(RequestTelemetry.ATTRIBUTE, telemetry);
      response.setHeader("x-correlation-id", serverSpan.traceContext().correlationId());
      response.setHeader("x-trace-id", serverSpan.traceContext().traceId());
      response.setHeader("traceparent", serverSpan.traceContext().traceparent());
      if (!serverSpan.traceContext().traceState().isBlank()) {
        response.setHeader("tracestate", serverSpan.traceContext().traceState());
      }
      response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");

      try {
        if (!acceptsJson(request)
            || ("GET".equalsIgnoreCase(request.getMethod()) && hasInput(request))
            || !resolution.correlationIdValid()) {
          telemetry.markFailure("validation_error", 0, null);
          writeValidationError(response);
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
        serverSpan.complete(response.getStatus(), telemetry.errorType());
        structuredLogger.request(
            telemetry, response.getStatus(), elapsedMillis(startedAt), request.getMethod());
      }
    }
  }

  private void writeValidationError(HttpServletResponse response) throws IOException {
    response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
    response.setContentType(MediaType.APPLICATION_JSON_VALUE);
    objectMapper.writeValue(response.getOutputStream(), VALIDATION_ERROR);
  }

  private static boolean hasInput(HttpServletRequest request) {
    return request.getQueryString() != null
        || request.getContentLengthLong() > 0
        || request.getHeader(HttpHeaders.TRANSFER_ENCODING) != null;
  }

  private static long elapsedMillis(long startedAt) {
    return Math.max(0, TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt));
  }

  private static boolean acceptsJson(HttpServletRequest request) {
    String accept = request.getHeader(HttpHeaders.ACCEPT);
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

package com.schwab.risk.gateway.api;

import com.schwab.risk.gateway.api.model.ErrorResponse;
import com.schwab.risk.gateway.client.DependencyUnavailableException;
import com.schwab.risk.gateway.client.DownstreamTimeoutException;
import com.schwab.risk.gateway.telemetry.RequestTelemetry;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.HttpMediaTypeNotAcceptableException;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice(assignableTypes = RiskController.class)
public class ApiExceptionHandler {

  @ExceptionHandler({
    MethodArgumentNotValidException.class,
    HttpMessageNotReadableException.class,
    HttpMediaTypeNotSupportedException.class
  })
  ResponseEntity<ErrorResponse> validationFailure(Exception exception, HttpServletRequest request) {
    telemetry(request).markFailure("validation_error", 0, null);
    return response(HttpStatus.BAD_REQUEST, "VALIDATION_ERROR", "Request validation failed");
  }

  @ExceptionHandler(HttpMediaTypeNotAcceptableException.class)
  ResponseEntity<Void> unacceptableResponse(
      HttpMediaTypeNotAcceptableException exception, HttpServletRequest request) {
    telemetry(request).markFailure("validation_error", 0, null);
    return ResponseEntity.badRequest().build();
  }

  @ExceptionHandler(DownstreamTimeoutException.class)
  ResponseEntity<ErrorResponse> downstreamTimeout(
      DownstreamTimeoutException exception, HttpServletRequest request) {
    telemetry(request)
        .markFailure("downstream_timeout", exception.downstreamLatencyMs(), exception);
    return response(HttpStatus.GATEWAY_TIMEOUT, "DOWNSTREAM_TIMEOUT", "Risk evaluation timed out");
  }

  @ExceptionHandler(DependencyUnavailableException.class)
  ResponseEntity<ErrorResponse> dependencyUnavailable(
      DependencyUnavailableException exception, HttpServletRequest request) {
    telemetry(request)
        .markFailure(exception.errorType(), exception.downstreamLatencyMs(), exception);
    return response(
        HttpStatus.SERVICE_UNAVAILABLE,
        "DEPENDENCY_UNAVAILABLE",
        "Risk evaluation is temporarily unavailable");
  }

  @ExceptionHandler(Exception.class)
  ResponseEntity<ErrorResponse> unexpectedFailure(Exception exception, HttpServletRequest request) {
    telemetry(request).markFailure("internal_error", 0, exception);
    return response(
        HttpStatus.SERVICE_UNAVAILABLE,
        "SERVICE_UNAVAILABLE",
        "Risk evaluation is temporarily unavailable");
  }

  private static RequestTelemetry telemetry(HttpServletRequest request) {
    Object value = request.getAttribute(RequestTelemetry.ATTRIBUTE);
    if (value instanceof RequestTelemetry requestTelemetry) {
      return requestTelemetry;
    }
    throw new IllegalStateException("Request telemetry was not initialized");
  }

  private static ResponseEntity<ErrorResponse> response(
      HttpStatus status, String error, String message) {
    return ResponseEntity.status(status).body(new ErrorResponse(error, message));
  }
}

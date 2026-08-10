package com.schwab.exchange.gateway.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Locale;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public final class SecurityResponseHeadersFilter extends OncePerRequestFilter {

  static final String CONTENT_SECURITY_POLICY =
      "default-src 'none'; "
          + "script-src 'sha256-oyGuofv9//RyMH/7VQwVrJ/vF8TYjwB0BeVProcmG+Q='; "
          + "style-src 'sha256-P9bnUBuQ4W03qFSsQaCTYhosTNMbOJQ6TnRvi01dQl8='; "
          + "img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; "
          + "frame-ancestors 'none'";
  static final String HSTS_POLICY = "max-age=31536000; includeSubDomains";

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
      throws ServletException, IOException {
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("X-Frame-Options", "DENY");
    response.setHeader("Content-Security-Policy", CONTENT_SECURITY_POLICY);
    if (originalRequestWasHttps(request)) {
      response.setHeader("Strict-Transport-Security", HSTS_POLICY);
    }
    filterChain.doFilter(request, response);
  }

  private static boolean originalRequestWasHttps(HttpServletRequest request) {
    if (request.isSecure()) {
      return true;
    }

    String forwardedProto = firstForwardedValue(request.getHeader("X-Forwarded-Proto"));
    if (forwardedProto != null) {
      return "https".equalsIgnoreCase(forwardedProto);
    }

    String forwarded = firstForwardedValue(request.getHeader("Forwarded"));
    if (forwarded == null) {
      return false;
    }
    for (String parameter : forwarded.split(";")) {
      String normalized = parameter.trim().toLowerCase(Locale.ROOT);
      if (normalized.equals("proto=https") || normalized.equals("proto=\"https\"")) {
        return true;
      }
    }
    return false;
  }

  private static String firstForwardedValue(String value) {
    if (value == null || value.isBlank()) {
      return null;
    }
    int separator = value.indexOf(',');
    return (separator < 0 ? value : value.substring(0, separator)).trim();
  }
}

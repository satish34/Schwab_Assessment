package com.schwab.exchange.gateway.security;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

class SecurityResponseHeadersFilterTest {

  private final SecurityResponseHeadersFilter filter = new SecurityResponseHeadersFilter();

  @Test
  void addsHstsForForwardedHttpsAndAllBaselineHeaders() throws Exception {
    MockHttpServletRequest request = new MockHttpServletRequest("GET", "/");
    request.addHeader("X-Forwarded-Proto", "https");
    MockHttpServletResponse response = new MockHttpServletResponse();

    filter.doFilter(request, response, new MockFilterChain());

    assertThat(response.getHeader("Strict-Transport-Security"))
        .isEqualTo(SecurityResponseHeadersFilter.HSTS_POLICY);
    assertThat(response.getHeader("X-Content-Type-Options")).isEqualTo("nosniff");
    assertThat(response.getHeader("X-Frame-Options")).isEqualTo("DENY");
    assertThat(response.getHeader("Content-Security-Policy"))
        .isEqualTo(SecurityResponseHeadersFilter.CONTENT_SECURITY_POLICY)
        .doesNotContain("'unsafe-inline'");
  }

  @Test
  void omitsHstsForLocalHttp() throws Exception {
    MockHttpServletRequest request = new MockHttpServletRequest("GET", "/");
    MockHttpServletResponse response = new MockHttpServletResponse();

    filter.doFilter(request, response, new MockFilterChain());

    assertThat(response.getHeader("Strict-Transport-Security")).isNull();
    assertThat(response.getHeader("X-Content-Type-Options")).isEqualTo("nosniff");
  }

  @Test
  void addsHstsForAnOriginalSecureRequestAndStandardForwardedHeader() throws Exception {
    MockHttpServletRequest secureRequest = new MockHttpServletRequest("GET", "/");
    secureRequest.setSecure(true);
    MockHttpServletResponse secureResponse = new MockHttpServletResponse();
    filter.doFilter(secureRequest, secureResponse, new MockFilterChain());

    MockHttpServletRequest forwardedRequest = new MockHttpServletRequest("GET", "/");
    forwardedRequest.addHeader("Forwarded", "for=192.0.2.10;proto=https;host=satish.store");
    MockHttpServletResponse forwardedResponse = new MockHttpServletResponse();
    filter.doFilter(forwardedRequest, forwardedResponse, new MockFilterChain());

    assertThat(secureResponse.getHeader("Strict-Transport-Security"))
        .isEqualTo(SecurityResponseHeadersFilter.HSTS_POLICY);
    assertThat(forwardedResponse.getHeader("Strict-Transport-Security"))
        .isEqualTo(SecurityResponseHeadersFilter.HSTS_POLICY);
  }

  @Test
  void cspHashesMatchTheCurrentInlineStyleAndScriptExactly() throws Exception {
    String html =
        new ClassPathResource("static/index.html")
            .getContentAsString(StandardCharsets.UTF_8)
            .replace("\r\n", "\n")
            .replace('\r', '\n');

    assertThat(SecurityResponseHeadersFilter.CONTENT_SECURITY_POLICY)
        .contains("'" + hashSource(html, "style") + "'")
        .contains("'" + hashSource(html, "script") + "'");
  }

  private static String hashSource(String html, String element) throws Exception {
    var matcher =
        Pattern.compile("<" + element + ">(.*?)</" + element + ">", Pattern.DOTALL).matcher(html);
    assertThat(matcher.find()).isTrue();
    byte[] digest =
        MessageDigest.getInstance("SHA-256")
            .digest(matcher.group(1).getBytes(StandardCharsets.UTF_8));
    return "sha256-" + Base64.getEncoder().encodeToString(digest);
  }
}

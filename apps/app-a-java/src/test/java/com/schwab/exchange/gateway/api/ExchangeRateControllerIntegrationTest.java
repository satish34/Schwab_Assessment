package com.schwab.exchange.gateway.api;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.exchange.gateway.TestExchangeRateFixtures;
import com.schwab.exchange.gateway.api.model.ExchangeRatesResponse;
import com.schwab.exchange.gateway.client.AppBClient;
import com.schwab.exchange.gateway.client.DependencyUnavailableException;
import com.schwab.exchange.gateway.client.DownstreamResult;
import com.schwab.exchange.gateway.client.DownstreamTimeoutException;
import com.schwab.exchange.gateway.telemetry.TraceContext;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = "exchange.probe-enabled=false")
@AutoConfigureMockMvc
@ExtendWith(OutputCaptureExtension.class)
class ExchangeRateControllerIntegrationTest {

  private static final String CORRELATION_ID = "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824";
  private static final String TRACEPARENT =
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
  private static final String DISCLAIMER = TestExchangeRateFixtures.DISCLAIMER;

  @Autowired private MockMvc mockMvc;

  @Autowired private ObjectMapper objectMapper;

  @MockitoBean private AppBClient appBClient;

  private ExchangeRatesResponse response;

  @BeforeEach
  void setUp() {
    response = TestExchangeRateFixtures.response();
  }

  @Test
  void preservesAndForwardsCorrelationAndTraceContext() throws Exception {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(false)))
        .thenReturn(new DownstreamResult(response, 31));

    var result =
        mockMvc
            .perform(
                get("/api/exchange-rates")
                    .accept(MediaType.APPLICATION_JSON)
                    .header("x-correlation-id", CORRELATION_ID)
                    .header("traceparent", TRACEPARENT))
            .andExpect(status().isOk())
            .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
            .andExpect(header().stringValues(HttpHeaders.CACHE_CONTROL, "no-store"))
            .andExpect(header().string("x-correlation-id", CORRELATION_ID))
            .andExpect(header().string("traceparent", TRACEPARENT))
            .andExpect(jsonPath("$.baseCurrency").value("USD"))
            .andExpect(jsonPath("$.rateSnapshots.length()").value(10))
            .andExpect(jsonPath("$.rateSnapshots[0].EUR").value(0.92))
            .andExpect(jsonPath("$.rateSnapshots[0].GBP").value(0.78))
            .andExpect(jsonPath("$.rateSnapshots[0].JPY").value(149.50))
            .andExpect(jsonPath("$.rateSnapshots[9].EUR").value(0.92))
            .andExpect(jsonPath("$.rateSnapshots[9].GBP").value(0.78))
            .andExpect(jsonPath("$.rateSnapshots[9].JPY").value(149.90))
            .andExpect(jsonPath("$.disclaimer").value(DISCLAIMER))
            .andExpect(jsonPath("$.providedBy.service").value("app-b-engine"))
            .andExpect(jsonPath("$.providedBy.region").value("us-central1"))
            .andExpect(jsonPath("$.providedBy.cluster").value("gke-risk-usc1"))
            .andExpect(jsonPath("$.providedBy.version").value("abc123"))
            .andReturn();

    assertThat(result.getResponse().getHeaders(HttpHeaders.CACHE_CONTROL))
        .containsExactly("no-store");

    ArgumentCaptor<TraceContext> traceCaptor = ArgumentCaptor.forClass(TraceContext.class);
    verify(appBClient).getExchangeRates(traceCaptor.capture(), eq(false));
    assertThat(traceCaptor.getValue().correlationId()).isEqualTo(CORRELATION_ID);
    assertThat(traceCaptor.getValue().traceparent()).isEqualTo(TRACEPARENT);
  }

  @Test
  void generatesCorrelationAndTraceContextWhenHeadersAreAbsent() throws Exception {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(false)))
        .thenReturn(new DownstreamResult(response, 4));

    String generatedCorrelation =
        mockMvc
            .perform(get("/api/exchange-rates"))
            .andExpect(status().isOk())
            .andExpect(header().exists("x-correlation-id"))
            .andExpect(header().exists("traceparent"))
            .andReturn()
            .getResponse()
            .getHeader("x-correlation-id");

    assertThat(UUID.fromString(generatedCorrelation).toString()).isEqualTo(generatedCorrelation);
    ArgumentCaptor<TraceContext> traceCaptor = ArgumentCaptor.forClass(TraceContext.class);
    verify(appBClient).getExchangeRates(traceCaptor.capture(), eq(false));
    assertThat(traceCaptor.getValue().correlationId()).isEqualTo(generatedCorrelation);
    assertThat(traceCaptor.getValue().traceId()).matches("[0-9a-f]{32}");
  }

  @Test
  void rejectsQueryInputWithoutCallingAppB() throws Exception {
    mockMvc
        .perform(get("/api/exchange-rates").queryParam("base", "EUR"))
        .andExpect(status().isBadRequest())
        .andExpect(header().stringValues(HttpHeaders.CACHE_CONTROL, "no-store"))
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"))
        .andExpect(jsonPath("$.message").value("Request validation failed"));

    verifyNoInteractions(appBClient);
  }

  @Test
  void rejectsRequestBodyWithoutCallingAppB() throws Exception {
    mockMvc
        .perform(get("/api/exchange-rates").contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"));

    verifyNoInteractions(appBClient);
  }

  @Test
  void rejectsAnUnsupportedAcceptTypeWithinTheStatusContract() throws Exception {
    mockMvc
        .perform(get("/api/exchange-rates").accept(MediaType.TEXT_PLAIN))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"));

    verifyNoInteractions(appBClient);
  }

  @Test
  void rejectsInvalidCorrelationHeaderWithoutCallingAppB() throws Exception {
    mockMvc
        .perform(get("/api/exchange-rates").header("x-correlation-id", "not-a-uuid"))
        .andExpect(status().isBadRequest())
        .andExpect(header().exists("x-correlation-id"))
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"));

    verify(appBClient, never()).getExchangeRates(any(), eq(false));
  }

  @Test
  void successLogKeepsTheFrozenSchemaAndUsesTheGetOutcome(CapturedOutput output) throws Exception {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(false)))
        .thenReturn(new DownstreamResult(response, 7));
    int outputStart = output.getAll().length();

    mockMvc.perform(get("/api/exchange-rates")).andExpect(status().isOk());

    List<JsonNode> requestEvents =
        output
            .getAll()
            .substring(outputStart)
            .lines()
            .filter(line -> !line.isBlank())
            .map(this::parse)
            .filter(event -> "request".equals(event.path("log_type").asText()))
            .toList();
    assertThat(requestEvents).hasSize(1);
    JsonNode event = requestEvents.getFirst();
    assertThat(event.properties()).hasSize(19);
    assertThat(event.path("route").asText()).isEqualTo("/api/exchange-rates");
    assertThat(event.path("method").asText()).isEqualTo("GET");
    assertThat(event.path("decision").asText()).isEqualTo("RATES_RETURNED");
  }

  @Test
  void rejectsTheFormerPostContract() throws Exception {
    mockMvc
        .perform(post("/api/exchange-rates"))
        .andExpect(status().isMethodNotAllowed())
        .andExpect(header().stringValues(HttpHeaders.CACHE_CONTROL, "no-store"));

    verifyNoInteractions(appBClient);
  }

  @Test
  void mapsDownstreamTimeoutWithoutLeakingExceptionText() throws Exception {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(false)))
        .thenThrow(new DownstreamTimeoutException(751, new RuntimeException("private detail")));

    String body =
        mockMvc
            .perform(get("/api/exchange-rates"))
            .andExpect(status().isGatewayTimeout())
            .andExpect(header().stringValues(HttpHeaders.CACHE_CONTROL, "no-store"))
            .andExpect(jsonPath("$.error").value("DOWNSTREAM_TIMEOUT"))
            .andExpect(jsonPath("$.message").value("Exchange-rate service timed out"))
            .andReturn()
            .getResponse()
            .getContentAsString();

    assertThat(body).doesNotContain("private detail");
  }

  @Test
  void mapsUnavailableDependencyToServiceUnavailable() throws Exception {
    when(appBClient.getExchangeRates(any(TraceContext.class), eq(false)))
        .thenThrow(
            new DependencyUnavailableException(
                "dependency_unavailable", 8, new RuntimeException("private detail")));

    String body =
        mockMvc
            .perform(get("/api/exchange-rates"))
            .andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.error").value("DEPENDENCY_UNAVAILABLE"))
            .andExpect(jsonPath("$.message").value("Exchange rates are temporarily unavailable"))
            .andReturn()
            .getResponse()
            .getContentAsString();

    assertThat(body).doesNotContain("private detail");
  }

  @Test
  void servesTheStaticDemoUiWithoutCaching() throws Exception {
    String html =
        mockMvc
            .perform(get("/"))
            .andExpect(status().isOk())
            .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
            .andExpect(header().stringValues(HttpHeaders.CACHE_CONTROL, "no-store"))
            .andReturn()
            .getResponse()
            .getContentAsString();

    assertThat(html)
        .contains("id=\"exchange-rate-app\"")
        .contains("data-api-endpoint=\"/api/exchange-rates\"")
        .contains("data-snapshot-count=\"10\"")
        .contains("id=\"sample-position\"")
        .contains("Synthetic demonstration rates - not for financial use.")
        .contains("data-currency=\"EUR\"")
        .contains("data-currency=\"GBP\"")
        .contains("data-currency=\"JPY\"")
        .contains("<title>Demo Currency Rate Board</title>")
        .contains("<link rel=\"icon\"")
        .contains("let sampleIndex = -1")
        .contains("payload.rateSnapshots.length !== 10")
        .contains("if (advanceSample || sampleIndex < 0)")
        .contains("sampleIndex = (sampleIndex + 1) % payload.rateSnapshots.length")
        .contains("Number(rates[currency]).toFixed(2)")
        .contains("clearDisplayedRates();")
        .contains("cache: \"no-store\"")
        .contains("loadRates(true)")
        .contains("loadRates(false)")
        .doesNotContain("headers: { Accept");
    assertThat(html.indexOf("await fetch(endpoint"))
        .isLessThan(html.indexOf("sampleIndex = (sampleIndex + 1)"));
    verifyNoInteractions(appBClient);
  }

  private JsonNode parse(String line) {
    try {
      return objectMapper.readTree(line);
    } catch (Exception exception) {
      throw new AssertionError("Expected one JSON object per physical log line", exception);
    }
  }
}

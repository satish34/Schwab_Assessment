package com.schwab.risk.gateway.api;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.schwab.risk.gateway.api.model.Decision;
import com.schwab.risk.gateway.api.model.EvaluatedBy;
import com.schwab.risk.gateway.api.model.RiskRequest;
import com.schwab.risk.gateway.api.model.RiskResponse;
import com.schwab.risk.gateway.client.AppBClient;
import com.schwab.risk.gateway.client.DependencyUnavailableException;
import com.schwab.risk.gateway.client.DownstreamResult;
import com.schwab.risk.gateway.client.DownstreamTimeoutException;
import com.schwab.risk.gateway.telemetry.TraceContext;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = "risk.probe-enabled=false")
@AutoConfigureMockMvc
@ExtendWith(OutputCaptureExtension.class)
class RiskControllerIntegrationTest {

  private static final UUID REQUEST_ID = UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
  private static final String CORRELATION_ID = "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824";
  private static final String TRACEPARENT =
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
  private static final String VALID_REQUEST =
      """
      {
        "requestId":"550e8400-e29b-41d4-a716-446655440000",
        "amount":1250.50,
        "currency":"USD",
        "merchantCategory":"ELECTRONICS",
        "countryCode":"US",
        "channel":"CARD_NOT_PRESENT"
      }
      """;

  @Autowired private MockMvc mockMvc;

  @Autowired private ObjectMapper objectMapper;

  @MockitoBean private AppBClient appBClient;

  private RiskResponse response;

  @BeforeEach
  void setUp() {
    response =
        new RiskResponse(
            REQUEST_ID,
            48,
            Decision.REVIEW,
            List.of("CARD_NOT_PRESENT", "AMOUNT_OVER_1000"),
            new EvaluatedBy("app-b-engine", "us-central1", "gke-risk-usc1", "abc123"));
  }

  @Test
  void preservesAndForwardsCorrelationAndTraceContext() throws Exception {
    when(appBClient.evaluate(any(RiskRequest.class), any(TraceContext.class), eq(false)))
        .thenReturn(new DownstreamResult(response, 31));

    mockMvc
        .perform(
            post("/v1/risk")
                .contentType(MediaType.APPLICATION_JSON)
                .header("x-correlation-id", CORRELATION_ID)
                .header("traceparent", TRACEPARENT)
                .content(VALID_REQUEST))
        .andExpect(status().isOk())
        .andExpect(header().string("x-correlation-id", CORRELATION_ID))
        .andExpect(header().string("traceparent", TRACEPARENT))
        .andExpect(jsonPath("$.requestId").value(REQUEST_ID.toString()))
        .andExpect(jsonPath("$.score").value(48))
        .andExpect(jsonPath("$.decision").value("REVIEW"))
        .andExpect(jsonPath("$.evaluatedBy.service").value("app-b-engine"));

    ArgumentCaptor<TraceContext> traceCaptor = ArgumentCaptor.forClass(TraceContext.class);
    verify(appBClient).evaluate(any(RiskRequest.class), traceCaptor.capture(), eq(false));
    assertThat(traceCaptor.getValue().correlationId()).isEqualTo(CORRELATION_ID);
    assertThat(traceCaptor.getValue().traceparent()).isEqualTo(TRACEPARENT);
  }

  @Test
  void generatesCorrelationAndTraceContextWhenHeadersAreAbsent() throws Exception {
    when(appBClient.evaluate(any(RiskRequest.class), any(TraceContext.class), eq(false)))
        .thenReturn(new DownstreamResult(response, 4));

    String generatedCorrelation =
        mockMvc
            .perform(
                post("/v1/risk").contentType(MediaType.APPLICATION_JSON).content(VALID_REQUEST))
            .andExpect(status().isOk())
            .andExpect(header().exists("x-correlation-id"))
            .andExpect(header().exists("traceparent"))
            .andReturn()
            .getResponse()
            .getHeader("x-correlation-id");

    assertThatCodeParsesAsUuid(generatedCorrelation);
    ArgumentCaptor<TraceContext> traceCaptor = ArgumentCaptor.forClass(TraceContext.class);
    verify(appBClient).evaluate(any(RiskRequest.class), traceCaptor.capture(), eq(false));
    assertThat(traceCaptor.getValue().correlationId()).isEqualTo(generatedCorrelation);
    assertThat(traceCaptor.getValue().traceId()).matches("[0-9a-f]{32}");
  }

  @Test
  void rejectsInvalidBodyWithoutCallingAppB() throws Exception {
    mockMvc
        .perform(
            post("/v1/risk")
                .contentType(MediaType.APPLICATION_JSON)
                .content(VALID_REQUEST.replace("1250.50", "-1.00")))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"))
        .andExpect(jsonPath("$.message").value("Request validation failed"));

    verifyNoInteractions(appBClient);
  }

  @ParameterizedTest
  @ValueSource(strings = {"text/plain", "application/xml"})
  void rejectsUnsupportedContentTypesAsValidationFailures(String contentType) throws Exception {
    mockMvc
        .perform(post("/v1/risk").contentType(contentType).content(VALID_REQUEST))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"))
        .andExpect(jsonPath("$.message").value("Request validation failed"));

    verifyNoInteractions(appBClient);
  }

  @Test
  void rejectsAnUnsupportedAcceptTypeWithinTheFrozenStatusContract() throws Exception {
    mockMvc
        .perform(
            post("/v1/risk")
                .contentType(MediaType.APPLICATION_JSON)
                .accept(MediaType.TEXT_PLAIN)
                .content(VALID_REQUEST))
        .andExpect(status().isBadRequest());

    verifyNoInteractions(appBClient);
  }

  @Test
  void companionLogUsesTheActualRequestMethod(CapturedOutput output) throws Exception {
    int outputStart = output.getAll().length();

    mockMvc.perform(get("/v1/risk")).andExpect(status().isMethodNotAllowed());

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
    assertThat(requestEvents.getFirst().path("route").asText()).isEqualTo("/v1/risk");
    assertThat(requestEvents.getFirst().path("method").asText()).isEqualTo("GET");
    verifyNoInteractions(appBClient);
  }

  @Test
  void rejectsInvalidCorrelationHeaderWithoutCallingAppB() throws Exception {
    mockMvc
        .perform(
            post("/v1/risk")
                .contentType(MediaType.APPLICATION_JSON)
                .header("x-correlation-id", "not-a-uuid")
                .content(VALID_REQUEST))
        .andExpect(status().isBadRequest())
        .andExpect(header().exists("x-correlation-id"))
        .andExpect(jsonPath("$.error").value("VALIDATION_ERROR"));

    verify(appBClient, never()).evaluate(any(), any(), eq(false));
  }

  @Test
  void mapsDownstreamTimeoutWithoutLeakingExceptionText() throws Exception {
    when(appBClient.evaluate(any(RiskRequest.class), any(TraceContext.class), eq(false)))
        .thenThrow(new DownstreamTimeoutException(751, new RuntimeException("private detail")));

    String body =
        mockMvc
            .perform(
                post("/v1/risk").contentType(MediaType.APPLICATION_JSON).content(VALID_REQUEST))
            .andExpect(status().isGatewayTimeout())
            .andExpect(jsonPath("$.error").value("DOWNSTREAM_TIMEOUT"))
            .andReturn()
            .getResponse()
            .getContentAsString();

    assertThat(body).doesNotContain("private detail");
  }

  @Test
  void mapsUnavailableDependencyToServiceUnavailable() throws Exception {
    when(appBClient.evaluate(any(RiskRequest.class), any(TraceContext.class), eq(false)))
        .thenThrow(
            new DependencyUnavailableException(
                "dependency_unavailable", 8, new RuntimeException("private detail")));

    String body =
        mockMvc
            .perform(
                post("/v1/risk").contentType(MediaType.APPLICATION_JSON).content(VALID_REQUEST))
            .andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.error").value("DEPENDENCY_UNAVAILABLE"))
            .andReturn()
            .getResponse()
            .getContentAsString();

    assertThat(body).doesNotContain("private detail");
  }

  private static void assertThatCodeParsesAsUuid(String value) {
    assertThat(UUID.fromString(value).toString()).isEqualTo(value);
  }

  private JsonNode parse(String line) {
    try {
      return objectMapper.readTree(line);
    } catch (Exception exception) {
      throw new AssertionError("Expected one JSON object per physical log line", exception);
    }
  }
}

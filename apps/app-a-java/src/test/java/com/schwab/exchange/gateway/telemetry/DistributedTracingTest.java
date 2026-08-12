package com.schwab.exchange.gateway.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.schwab.exchange.gateway.config.AppAProperties;
import com.schwab.exchange.gateway.config.AppBAuthMode;
import com.schwab.exchange.gateway.config.TelemetryProperties;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.propagation.ContextPropagators;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.testing.exporter.InMemorySpanExporter;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import io.opentelemetry.sdk.trace.export.SpanExporter;
import io.opentelemetry.sdk.trace.samplers.Sampler;
import java.net.URI;
import java.time.Duration;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class DistributedTracingTest {

  private static final String CORRELATION_ID = "2d2e6e51-e5a6-4bc2-bf6c-e964876c6824";
  private static final String TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736";
  private static final String UPSTREAM_SPAN_ID = "00f067aa0ba902b7";
  private static final String TRACEPARENT = "00-" + TRACE_ID + "-" + UPSTREAM_SPAN_ID + "-01";

  @Test
  void createsAProperServerToClientW3cSpanChainWithTheReviewerVisibleTraceId() {
    InMemorySpanExporter exporter = InMemorySpanExporter.create();
    try (SdkTracerProvider provider = provider(exporter)) {
      DistributedTracing tracing = DistributedTracing.forTesting(openTelemetry(provider));
      TraceResolution resolution = new TraceContextResolver().resolve(CORRELATION_ID, TRACEPARENT);
      String serverSpanId;
      String clientSpanId;

      try (DistributedTracing.TraceSpan server =
          tracing.startServerSpan(resolution, "GET", "/api/exchange-rates")) {
        serverSpanId = spanId(server.traceContext().traceparent());
        assertThat(server.traceContext().traceId()).isEqualTo(TRACE_ID);
        assertThat(server.traceContext().correlationId()).isEqualTo(CORRELATION_ID);

        try (DistributedTracing.TraceSpan client =
            tracing.startClientSpan(server.traceContext(), false, 0)) {
          clientSpanId = spanId(client.traceContext().traceparent());
          assertThat(client.traceContext().traceId()).isEqualTo(TRACE_ID);
          assertThat(clientSpanId).isNotEqualTo(serverSpanId);
          client.complete(200, "");
        }
        server.complete(200, "");
      }

      List<SpanData> spans = exporter.getFinishedSpanItems();
      assertThat(spans).hasSize(2);
      SpanData server = named(spans, "GET /api/exchange-rates");
      SpanData client = named(spans, "GET app-b-engine/internal/exchange-rates");
      assertThat(server.getTraceId()).isEqualTo(TRACE_ID);
      assertThat(server.getParentSpanId()).isEqualTo(UPSTREAM_SPAN_ID);
      assertThat(server.getSpanId()).isEqualTo(serverSpanId);
      assertThat(client.getTraceId()).isEqualTo(TRACE_ID);
      assertThat(client.getParentSpanId()).isEqualTo(serverSpanId);
      assertThat(client.getSpanId()).isEqualTo(clientSpanId);
      for (SpanData span : spans) {
        assertThat(span.getAttributes().get(AttributeKey.stringKey("assessment.service.name")))
            .isEqualTo("app-a-gateway");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("assessment.service.version")))
            .isEqualTo("test-version");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("assessment.cloud.region")))
            .isEqualTo("test-region");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("assessment.k8s.cluster.name")))
            .isEqualTo("test-cluster");
      }
    }
  }

  @Test
  void generatedRootContextUsesValidW3cLevelTwoRandomTraceFlags() {
    assertGeneratedRootFlag(Sampler.alwaysOff(), "02");
    assertGeneratedRootFlag(Sampler.alwaysOn(), "03");
  }

  @Test
  void telemetryExporterFailureCannotEscapeIntoTheRequestPath() {
    SpanExporter failingExporter =
        new SpanExporter() {
          @Override
          public CompletableResultCode export(Collection<SpanData> spans) {
            return CompletableResultCode.ofFailure();
          }

          @Override
          public CompletableResultCode flush() {
            return CompletableResultCode.ofSuccess();
          }

          @Override
          public CompletableResultCode shutdown() {
            return CompletableResultCode.ofSuccess();
          }
        };

    try (SdkTracerProvider provider = provider(failingExporter)) {
      DistributedTracing tracing = DistributedTracing.forTesting(openTelemetry(provider));
      TraceResolution resolution = new TraceContextResolver().resolve(CORRELATION_ID, TRACEPARENT);

      assertThatCode(
              () -> {
                try (DistributedTracing.TraceSpan span =
                    tracing.startServerSpan(resolution, "GET", "/api/exchange-rates")) {
                  span.complete(200, "");
                }
              })
          .doesNotThrowAnyException();
    }
  }

  @Test
  void anUnsampledProbeContextCreatesNoExportedSpan() {
    InMemorySpanExporter exporter = InMemorySpanExporter.create();
    try (SdkTracerProvider provider =
        SdkTracerProvider.builder()
            .setSampler(Sampler.parentBased(Sampler.traceIdRatioBased(0.0)))
            .addSpanProcessor(SimpleSpanProcessor.create(exporter))
            .build()) {
      DistributedTracing tracing = DistributedTracing.forTesting(openTelemetry(provider));
      TraceContext probe = new TraceContextResolver().newUnsampledTrace(CORRELATION_ID);

      // The production prober bypasses tracing entirely. Even if this dependency helper is called
      // accidentally, the explicit unsampled parent keeps the probe out of the exporter.
      try (DistributedTracing.TraceSpan span = tracing.startClientSpan(probe, true, 0)) {
        span.complete(200, "");
      }

      assertThat(exporter.getFinishedSpanItems()).isEmpty();
    }
  }

  @Test
  void locksDirectTraceOnlyExportAndBoundedRootSampling() {
    Map<String, String> configuration = DistributedTracing.configuration(properties());

    assertThat(configuration)
        .containsEntry("otel.exporter.otlp.endpoint", "https://telemetry.googleapis.com")
        .containsEntry("otel.exporter.otlp.protocol", "http/protobuf")
        .containsEntry("otel.traces.exporter", "otlp")
        .containsEntry("otel.metrics.exporter", "none")
        .containsEntry("otel.logs.exporter", "none")
        .containsEntry("otel.traces.sampler", "parentbased_traceidratio")
        .containsEntry("otel.traces.sampler.arg", "0.1")
        .containsEntry("google.cloud.project", "test-project")
        .containsEntry("google.otel.auth.target.signals", "traces");
    assertThat(configuration.get("otel.resource.attributes"))
        .contains("service.version=abc123")
        .contains("cloud.region=us-central1")
        .contains("k8s.cluster.name=test-cluster")
        .contains("gcp.project_id=test-project");
  }

  @Test
  void tracingEnabledWithoutAProjectFailsClosedAtStartup() {
    assertThatThrownBy(
            () -> DistributedTracing.create(new TelemetryProperties(true), properties("")))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("GOOGLE_CLOUD_PROJECT");
  }

  private static SdkTracerProvider provider(SpanExporter exporter) {
    return SdkTracerProvider.builder()
        .setSampler(Sampler.alwaysOn())
        .addSpanProcessor(SimpleSpanProcessor.create(exporter))
        .build();
  }

  private static void assertGeneratedRootFlag(Sampler sampler, String expectedFlag) {
    InMemorySpanExporter exporter = InMemorySpanExporter.create();
    try (SdkTracerProvider provider =
        SdkTracerProvider.builder()
            .setSampler(sampler)
            .addSpanProcessor(SimpleSpanProcessor.create(exporter))
            .build()) {
      DistributedTracing tracing = DistributedTracing.forTesting(openTelemetry(provider));
      TraceResolution resolution = new TraceContextResolver().resolve(null, null);

      try (DistributedTracing.TraceSpan server =
          tracing.startServerSpan(resolution, "GET", "/api/exchange-rates")) {
        String traceparent = server.traceContext().traceparent();
        assertThat(traceparent).matches("00-[0-9a-f]{32}-[0-9a-f]{16}-" + expectedFlag);
        assertThat(server.traceContext().traceId()).isEqualTo(traceparent.substring(3, 35));
        server.complete(200, "");
      }
    }
  }

  private static OpenTelemetry openTelemetry(SdkTracerProvider provider) {
    return OpenTelemetrySdk.builder()
        .setTracerProvider(provider)
        .setPropagators(ContextPropagators.create(W3CTraceContextPropagator.getInstance()))
        .build();
  }

  private static SpanData named(List<SpanData> spans, String name) {
    return spans.stream()
        .filter(span -> name.equals(span.getName()))
        .findFirst()
        .orElseThrow(() -> new AssertionError("Missing span " + name));
  }

  private static String spanId(String traceparent) {
    return traceparent.split("-")[2];
  }

  private static AppAProperties properties() {
    return properties("test-project");
  }

  private static AppAProperties properties(String project) {
    return new AppAProperties(
        "us-central1",
        "test-cluster",
        "abc123",
        URI.create("http://app-b-engine:8080"),
        AppBAuthMode.DISABLED,
        "https://app-b-engine.example.internal",
        project,
        Duration.ofMillis(500),
        Duration.ofMillis(750),
        Duration.ofSeconds(3),
        false,
        2000,
        3,
        5);
  }
}

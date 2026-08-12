package com.schwab.exchange.gateway.telemetry;

import com.schwab.exchange.gateway.config.AppAProperties;
import com.schwab.exchange.gateway.config.TelemetryProperties;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanBuilder;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.opentelemetry.context.propagation.TextMapGetter;
import io.opentelemetry.context.propagation.TextMapSetter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Owns App A's explicit customer-request and downstream-dependency spans.
 *
 * <p>Export is handled by a bounded asynchronous processor that authenticates to Google Cloud with
 * Application Default Credentials. Export failures can drop telemetry, but cannot fail or wait on
 * the customer request path. Health checks and background probes do not create spans.
 */
public final class DistributedTracing implements AutoCloseable {

  private static final String INSTRUMENTATION_SCOPE = "app-a-gateway";
  private static final AttributeKey<String> HTTP_METHOD =
      AttributeKey.stringKey("http.request.method");
  private static final AttributeKey<String> HTTP_ROUTE = AttributeKey.stringKey("http.route");
  private static final AttributeKey<Long> HTTP_STATUS =
      AttributeKey.longKey("http.response.status_code");
  private static final AttributeKey<String> URL_PATH = AttributeKey.stringKey("url.path");
  private static final AttributeKey<String> SERVER_ADDRESS =
      AttributeKey.stringKey("server.address");
  private static final AttributeKey<Long> SERVER_PORT = AttributeKey.longKey("server.port");
  private static final AttributeKey<Long> RETRY_ATTEMPT = AttributeKey.longKey("app.retry.attempt");
  private static final AttributeKey<Boolean> CELL_PROBE = AttributeKey.booleanKey("app.cell_probe");
  private static final AttributeKey<String> ERROR_TYPE = AttributeKey.stringKey("error.type");
  private static final AttributeKey<String> ASSESSMENT_SERVICE =
      AttributeKey.stringKey("assessment.service.name");
  private static final AttributeKey<String> ASSESSMENT_VERSION =
      AttributeKey.stringKey("assessment.service.version");
  private static final AttributeKey<String> ASSESSMENT_REGION =
      AttributeKey.stringKey("assessment.cloud.region");
  private static final AttributeKey<String> ASSESSMENT_CLUSTER =
      AttributeKey.stringKey("assessment.k8s.cluster.name");
  private static final TextMapGetter<Map<String, String>> MAP_GETTER =
      new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(Map<String, String> carrier) {
          return carrier.keySet();
        }

        @Override
        public String get(Map<String, String> carrier, String key) {
          return carrier.get(key);
        }
      };
  private static final TextMapSetter<Map<String, String>> MAP_SETTER = Map::put;

  private final OpenTelemetry openTelemetry;
  private final Tracer tracer;
  private final OpenTelemetrySdk sdk;
  private final boolean enabled;
  private final String appBHost;
  private final long appBPort;
  private final String serviceVersion;
  private final String region;
  private final String cluster;
  private final AtomicBoolean closed = new AtomicBoolean();

  private DistributedTracing(
      OpenTelemetry openTelemetry,
      OpenTelemetrySdk sdk,
      boolean enabled,
      String appBHost,
      long appBPort,
      String serviceVersion,
      String region,
      String cluster) {
    this.openTelemetry = openTelemetry;
    this.tracer = openTelemetry.getTracer(INSTRUMENTATION_SCOPE);
    this.sdk = sdk;
    this.enabled = enabled;
    this.appBHost = appBHost;
    this.appBPort = appBPort;
    this.serviceVersion = serviceVersion;
    this.region = region;
    this.cluster = cluster;
  }

  static DistributedTracing create(
      TelemetryProperties telemetryProperties, AppAProperties appAProperties) {
    if (!telemetryProperties.enabled()) {
      return disabled();
    }
    if (appAProperties.googleCloudProject() == null
        || appAProperties.googleCloudProject().isBlank()) {
      throw new IllegalStateException(
          "GOOGLE_CLOUD_PROJECT is required when distributed tracing is enabled");
    }
    Map<String, String> defaults = configuration(appAProperties);
    OpenTelemetrySdk configuredSdk =
        AutoConfiguredOpenTelemetrySdk.builder()
            // Keep the authenticated destination and cost controls immutable at runtime.
            .addPropertiesCustomizer(unused -> defaults)
            .disableShutdownHook()
            .build()
            .getOpenTelemetrySdk();
    return new DistributedTracing(
        configuredSdk,
        configuredSdk,
        true,
        appAProperties.appBBaseUrl().getHost(),
        resolvedPort(appAProperties),
        appAProperties.serviceVersion(),
        appAProperties.region(),
        appAProperties.cluster());
  }

  public static DistributedTracing disabled() {
    return new DistributedTracing(OpenTelemetry.noop(), null, false, "", 0, "", "", "");
  }

  public static DistributedTracing forTesting(OpenTelemetry openTelemetry) {
    return new DistributedTracing(
        openTelemetry,
        null,
        true,
        "app-b-engine",
        8080,
        "test-version",
        "test-region",
        "test-cluster");
  }

  public TraceSpan startServerSpan(TraceResolution resolution, String method, String route) {
    if (!enabled) {
      return TraceSpan.disabled(resolution.context());
    }

    SpanBuilder builder =
        tracer
            .spanBuilder(method + " " + route)
            .setSpanKind(SpanKind.SERVER)
            .setAttribute(HTTP_METHOD, method)
            .setAttribute(HTTP_ROUTE, route);
    setAssessmentIdentity(builder);
    if (resolution.remoteParent()) {
      builder.setParent(extract(resolution.context()));
    } else {
      builder.setNoParent();
    }
    return activate(builder.startSpan(), resolution.context().correlationId(), true);
  }

  public TraceSpan startClientSpan(TraceContext fallbackParent, boolean cellProbe, int attempt) {
    if (!enabled) {
      return TraceSpan.disabled(fallbackParent);
    }

    Context parent = Context.current();
    if (!Span.fromContext(parent).getSpanContext().isValid()) {
      parent = extract(fallbackParent);
    }
    SpanBuilder builder =
        tracer
            .spanBuilder("GET app-b-engine/internal/exchange-rates")
            .setParent(parent)
            .setSpanKind(SpanKind.CLIENT)
            .setAttribute(HTTP_METHOD, "GET")
            .setAttribute(URL_PATH, "/internal/exchange-rates")
            .setAttribute(SERVER_ADDRESS, appBHost)
            .setAttribute(SERVER_PORT, appBPort)
            .setAttribute(RETRY_ATTEMPT, attempt)
            .setAttribute(CELL_PROBE, cellProbe);
    setAssessmentIdentity(builder);
    Span span = builder.startSpan();
    return activate(span, fallbackParent.correlationId(), false);
  }

  private void setAssessmentIdentity(SpanBuilder builder) {
    builder
        .setAttribute(ASSESSMENT_SERVICE, INSTRUMENTATION_SCOPE)
        .setAttribute(ASSESSMENT_VERSION, serviceVersion)
        .setAttribute(ASSESSMENT_REGION, region)
        .setAttribute(ASSESSMENT_CLUSTER, cluster);
  }

  private TraceSpan activate(Span span, String correlationId, boolean serverSpan) {
    Scope scope = span.makeCurrent();
    return new TraceSpan(span, scope, propagatedContext(span, correlationId), serverSpan);
  }

  private Context extract(TraceContext traceContext) {
    Map<String, String> carrier = new HashMap<>();
    carrier.put("traceparent", traceContext.traceparent());
    if (!traceContext.traceState().isBlank()) {
      carrier.put("tracestate", traceContext.traceState());
    }
    return openTelemetry
        .getPropagators()
        .getTextMapPropagator()
        .extract(Context.root(), carrier, MAP_GETTER);
  }

  private TraceContext propagatedContext(Span span, String correlationId) {
    Map<String, String> carrier = new HashMap<>();
    openTelemetry
        .getPropagators()
        .getTextMapPropagator()
        .inject(Context.root().with(span), carrier, MAP_SETTER);
    return new TraceContext(
        correlationId,
        span.getSpanContext().getTraceId(),
        carrier.get("traceparent"),
        carrier.getOrDefault("tracestate", ""));
  }

  @Override
  public void close() {
    if (sdk != null && closed.compareAndSet(false, true)) {
      sdk.close();
    }
  }

  private static String resourceAttributes(AppAProperties properties) {
    return "service.version="
        + properties.serviceVersion()
        + ",cloud.region="
        + properties.region()
        + ",k8s.cluster.name="
        + properties.cluster()
        + ",gcp.project_id="
        + properties.googleCloudProject();
  }

  static Map<String, String> configuration(AppAProperties properties) {
    return Map.ofEntries(
        Map.entry("otel.sdk.disabled", "false"),
        Map.entry("otel.traces.exporter", "otlp"),
        Map.entry("otel.metrics.exporter", "none"),
        Map.entry("otel.logs.exporter", "none"),
        Map.entry("otel.exporter.otlp.endpoint", "https://telemetry.googleapis.com"),
        Map.entry("otel.exporter.otlp.protocol", "http/protobuf"),
        Map.entry("otel.exporter.otlp.timeout", "2000"),
        Map.entry("otel.java.exporter.otlp.retry.disabled", "false"),
        Map.entry("otel.bsp.schedule.delay", "1000"),
        Map.entry("otel.bsp.max.queue.size", "2048"),
        Map.entry("otel.bsp.max.export.batch.size", "512"),
        Map.entry("otel.bsp.export.timeout", "2000"),
        Map.entry("otel.traces.sampler", "parentbased_traceidratio"),
        Map.entry("otel.traces.sampler.arg", "0.1"),
        Map.entry("otel.propagators", "tracecontext"),
        Map.entry("otel.service.name", "app-a-gateway"),
        Map.entry("otel.resource.attributes", resourceAttributes(properties)),
        Map.entry("google.cloud.project", properties.googleCloudProject()),
        Map.entry("google.otel.auth.target.signals", "traces"));
  }

  private static long resolvedPort(AppAProperties properties) {
    int configuredPort = properties.appBBaseUrl().getPort();
    if (configuredPort > 0) {
      return configuredPort;
    }
    return "https".equalsIgnoreCase(properties.appBBaseUrl().getScheme()) ? 443 : 80;
  }

  public static final class TraceSpan implements AutoCloseable {

    private final Span span;
    private final Scope scope;
    private final TraceContext traceContext;
    private final boolean serverSpan;
    private boolean completed;

    private TraceSpan(Span span, Scope scope, TraceContext traceContext, boolean serverSpan) {
      this.span = span;
      this.scope = scope;
      this.traceContext = traceContext;
      this.serverSpan = serverSpan;
    }

    private static TraceSpan disabled(TraceContext traceContext) {
      return new TraceSpan(null, null, traceContext, false);
    }

    public TraceContext traceContext() {
      return traceContext;
    }

    public void complete(int statusCode, String errorType) {
      if (span == null || completed) {
        return;
      }
      completed = true;
      if (statusCode > 0) {
        span.setAttribute(HTTP_STATUS, statusCode);
      }
      if (errorType != null && !errorType.isBlank()) {
        span.setAttribute(ERROR_TYPE, safeErrorType(errorType));
      }
      boolean failed = statusCode >= 500 || (!serverSpan && statusCode >= 400);
      if (failed || (errorType != null && !errorType.isBlank() && statusCode >= 500)) {
        String safeErrorType = safeErrorType(errorType);
        span.setStatus(StatusCode.ERROR, safeErrorType);
      } else if (statusCode < 400) {
        span.setStatus(StatusCode.OK);
      }
    }

    @Override
    public void close() {
      if (span == null) {
        return;
      }
      if (!completed) {
        span.setStatus(StatusCode.ERROR, "unreported_failure");
        span.setAttribute(ERROR_TYPE, "unreported_failure");
      }
      try {
        scope.close();
      } finally {
        span.end();
      }
    }

    private static String safeErrorType(String errorType) {
      if (errorType == null || !errorType.matches("[a-z0-9_]{1,64}")) {
        return "request_failed";
      }
      return errorType;
    }
  }
}

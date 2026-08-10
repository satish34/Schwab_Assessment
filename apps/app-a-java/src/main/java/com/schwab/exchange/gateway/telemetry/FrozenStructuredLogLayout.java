package com.schwab.exchange.gateway.telemetry;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.classic.spi.IThrowableProxy;
import ch.qos.logback.classic.spi.StackTraceElementProxy;
import ch.qos.logback.core.LayoutBase;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

public final class FrozenStructuredLogLayout extends LayoutBase<ILoggingEvent> {

  private static final String SERVICE_NAME = "app-a-gateway";
  private static final int MAX_STACK_FRAMES = 32;
  private static final String FALLBACK_EVENT =
      "{\"severity\":\"ERROR\",\"message\":\"framework log serialization failed\","
          + "\"log_type\":\"lifecycle\",\"service\":\"app-a-gateway\","
          + "\"service_version\":\"\",\"region\":\"\",\"cluster\":\"\","
          + "\"correlation_id\":\"\",\"trace_id\":\"\",\"route\":\"\","
          + "\"method\":\"\",\"status_code\":0,\"latency_ms\":0,"
          + "\"downstream_latency_ms\":0,\"decision\":\"\",\"error_type\":\"\","
          + "\"stack_trace\":\"\",\"is_test\":false,"
          + "\"logging.googleapis.com/trace\":\"\"}";

  private final ObjectMapper objectMapper = new ObjectMapper();

  private String serviceVersion = "dev";
  private String region = "local";
  private String cluster = "local";
  private String googleCloudProject = "";

  @Override
  public String doLayout(ILoggingEvent event) {
    StructuredLogEvent structuredEvent =
        new StructuredLogEvent(
            cloudSeverity(event.getLevel()),
            text(event.getFormattedMessage()),
            "lifecycle",
            SERVICE_NAME,
            text(serviceVersion),
            text(region),
            text(cluster),
            mdc(event, "correlation_id"),
            mdc(event, "trace_id"),
            mdc(event, "route"),
            mdc(event, "method"),
            0,
            0,
            0,
            "",
            "",
            safeStackTrace(event.getThrowableProxy()),
            false,
            googleTrace(mdc(event, "trace_id")));
    try {
      return objectMapper.writeValueAsString(structuredEvent) + System.lineSeparator();
    } catch (JsonProcessingException ignored) {
      return FALLBACK_EVENT + System.lineSeparator();
    }
  }

  public void setServiceVersion(String serviceVersion) {
    this.serviceVersion = serviceVersion;
  }

  public void setRegion(String region) {
    this.region = region;
  }

  public void setCluster(String cluster) {
    this.cluster = cluster;
  }

  public void setGoogleCloudProject(String googleCloudProject) {
    this.googleCloudProject = googleCloudProject;
  }

  private String googleTrace(String traceId) {
    return googleCloudProject == null || googleCloudProject.isBlank() || traceId.isBlank()
        ? ""
        : "projects/" + googleCloudProject + "/traces/" + traceId;
  }

  private static String cloudSeverity(Level level) {
    if (level == null) {
      return "DEFAULT";
    }
    return switch (level.toInt()) {
      case Level.ERROR_INT -> "ERROR";
      case Level.WARN_INT -> "WARNING";
      case Level.INFO_INT -> "INFO";
      case Level.DEBUG_INT, Level.TRACE_INT -> "DEBUG";
      default -> "DEFAULT";
    };
  }

  private static String safeStackTrace(IThrowableProxy throwable) {
    if (throwable == null) {
      return "";
    }

    StringBuilder value =
        new StringBuilder(text(throwable.getClassName())).append(": framework processing failed");
    StackTraceElementProxy[] frames = throwable.getStackTraceElementProxyArray();
    if (frames != null) {
      for (int index = 0; index < Math.min(frames.length, MAX_STACK_FRAMES); index++) {
        value
            .append(System.lineSeparator())
            .append("\tat ")
            .append(frames[index].getStackTraceElement());
      }
    }
    return value.toString();
  }

  private static String mdc(ILoggingEvent event, String key) {
    return text(event.getMDCPropertyMap().get(key));
  }

  private static String text(String value) {
    return value == null ? "" : value;
  }
}

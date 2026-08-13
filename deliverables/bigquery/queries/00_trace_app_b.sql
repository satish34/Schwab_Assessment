SELECT
  timestamp,
  resource.labels.namespace_name AS namespace_name,
  resource.labels.pod_name AS pod_name,
  severity,
  jsonPayload.service AS service,
  jsonPayload.service_version AS service_version,
  jsonPayload.log_type AS log_type,
  jsonPayload.message AS message,
  jsonPayload.route AS route,
  SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code,
  SAFE_CAST(jsonPayload.latency_ms AS INT64) AS latency_ms,
  jsonPayload.correlation_id AS correlation_id,
  jsonPayload.error_type AS error_type,
  trace,
  spanId
FROM `PROJECT_ID.risk_logs.stdout`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
  AND resource.labels.namespace_name = 'currency-app-b'
  AND jsonPayload.trace_id = @trace_id
ORDER BY timestamp ASC;

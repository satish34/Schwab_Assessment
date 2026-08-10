WITH app_a AS (
  SELECT
    timestamp,
    jsonPayload.trace_id AS trace_id,
    jsonPayload.correlation_id AS correlation_id,
    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code,
    SAFE_CAST(jsonPayload.latency_ms AS INT64) AS latency_ms,
    jsonPayload.region AS region,
    jsonPayload.cluster AS cluster
  FROM `PROJECT_ID.risk_logs.stdout`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-a-gateway'
    AND jsonPayload.route = '/api/exchange-rates'
    AND jsonPayload.method = 'GET'
),
app_b AS (
  SELECT
    timestamp,
    jsonPayload.trace_id AS trace_id,
    jsonPayload.correlation_id AS correlation_id,
    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code,
    SAFE_CAST(jsonPayload.latency_ms AS INT64) AS latency_ms,
    jsonPayload.region AS region,
    jsonPayload.cluster AS cluster
  FROM `PROJECT_ID.risk_logs.stdout`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-b-engine'
    AND jsonPayload.route = '/internal/exchange-rates'
    AND jsonPayload.method = 'GET'
)
SELECT
  app_a.timestamp AS app_a_timestamp,
  app_b.timestamp AS app_b_timestamp,
  app_a.trace_id,
  app_a.correlation_id,
  app_a.region,
  app_a.cluster,
  app_a.status_code AS app_a_status,
  app_b.status_code AS app_b_status,
  app_a.latency_ms AS app_a_latency_ms,
  app_b.latency_ms AS app_b_latency_ms
FROM app_a
JOIN app_b
  ON app_a.trace_id = app_b.trace_id
  AND app_a.correlation_id = app_b.correlation_id
ORDER BY app_a.timestamp DESC
LIMIT 100;

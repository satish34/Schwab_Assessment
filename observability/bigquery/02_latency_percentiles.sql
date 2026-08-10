WITH buckets AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute,
    APPROX_QUANTILES(SAFE_CAST(jsonPayload.latency_ms AS INT64), 100) AS quantiles
  FROM `PROJECT_ID.risk_logs.stdout`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-a-gateway'
    AND jsonPayload.route = '/api/exchange-rates'
    AND jsonPayload.method = 'GET'
    AND jsonPayload.latency_ms IS NOT NULL
  GROUP BY minute
)
SELECT
  minute,
  quantiles[OFFSET(50)] AS p50_ms,
  quantiles[OFFSET(95)] AS p95_ms,
  quantiles[OFFSET(99)] AS p99_ms
FROM buckets
ORDER BY minute;

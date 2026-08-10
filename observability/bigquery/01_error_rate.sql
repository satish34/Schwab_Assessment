WITH requests AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute,
    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code
  FROM `PROJECT_ID.risk_logs.stdout`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-a-gateway'
    AND jsonPayload.route = '/api/exchange-rates'
    AND jsonPayload.method = 'GET'
)
SELECT
  minute,
  COUNT(*) AS request_count,
  COUNTIF(status_code >= 500) AS error_count,
  100 * SAFE_DIVIDE(COUNTIF(status_code >= 500), COUNT(*)) AS error_rate_pct
FROM requests
GROUP BY minute
ORDER BY minute;

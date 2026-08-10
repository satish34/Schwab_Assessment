WITH requests AS (
  SELECT
    $__timeGroup(timestamp, $__interval) AS time,
    jsonPayload.region AS region,
    jsonPayload.cluster AS cluster,
    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code
  FROM `schwab-assessment-gke.risk_logs.stdout`
  WHERE $__timeFilter(timestamp)
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-a-gateway'
    AND jsonPayload.route = '/api/exchange-rates'
    AND jsonPayload.method = 'GET'
)
SELECT
  time,
  CONCAT(region, ' / ', cluster) AS cell,
  100 * SAFE_DIVIDE(COUNTIF(status_code >= 500), COUNT(*)) AS error_rate_pct
FROM requests
GROUP BY time, region, cluster
ORDER BY time, cell;

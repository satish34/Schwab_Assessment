WITH public_requests AS (
  SELECT
    $__timeGroup(timestamp, $__interval) AS time,
    jsonPayload.region AS region,
    jsonPayload.cluster AS cluster,
    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code
  FROM `schwab-assessment-gke.risk_logs.stdout`
  WHERE $__timeFilter(timestamp)
    AND resource.labels.namespace_name = 'currency-app-a'
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-a-gateway'
    AND jsonPayload.route = '/api/exchange-rates'
    AND jsonPayload.method = 'GET'
),
internal_requests AS (
  SELECT
    $__timeGroup(timestamp, $__interval) AS time,
    jsonPayload.region AS region,
    jsonPayload.cluster AS cluster,
    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code,
    jsonPayload.decision AS decision
  FROM `schwab-assessment-gke.risk_logs.stdout`
  WHERE $__timeFilter(timestamp)
    AND resource.labels.namespace_name = 'currency-app-b'
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-b-engine'
    AND jsonPayload.route = '/internal/exchange-rates'
    AND jsonPayload.method = 'GET'
),
series AS (
  SELECT
    time,
    CONCAT(region, ' / ', cluster, ' / public 5xx') AS cell,
    100 * SAFE_DIVIDE(COUNTIF(status_code >= 500), COUNT(*)) AS error_rate_pct
  FROM public_requests
  GROUP BY time, region, cluster
  UNION ALL
  SELECT
    time,
    CONCAT(region, ' / ', cluster, ' / auth rejected') AS cell,
    100 * SAFE_DIVIDE(
      COUNTIF(status_code = 401 AND decision = 'AUTH_REJECTED'),
      COUNT(*)
    ) AS error_rate_pct
  FROM internal_requests
  GROUP BY time, region, cluster
)
SELECT time, cell, error_rate_pct
FROM series
ORDER BY time, cell;

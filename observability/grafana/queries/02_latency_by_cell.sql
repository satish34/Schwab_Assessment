WITH buckets AS (
  SELECT
    $__timeGroup(timestamp, $__interval) AS time,
    jsonPayload.region AS region,
    jsonPayload.cluster AS cluster,
    APPROX_QUANTILES(SAFE_CAST(jsonPayload.latency_ms AS INT64), 100) AS quantiles
  FROM `schwab-assessment-gke.risk_logs.stdout`
  WHERE $__timeFilter(timestamp)
    AND jsonPayload.log_type = 'request'
    AND jsonPayload.service = 'app-a-gateway'
    AND jsonPayload.route = '/api/exchange-rates'
    AND jsonPayload.method = 'GET'
    AND jsonPayload.latency_ms IS NOT NULL
  GROUP BY time, region, cluster
)
SELECT time, CONCAT(region, ' / ', cluster, ' / p50') AS series, quantiles[OFFSET(50)] AS latency_ms
FROM buckets
UNION ALL
SELECT time, CONCAT(region, ' / ', cluster, ' / p95') AS series, quantiles[OFFSET(95)] AS latency_ms
FROM buckets
UNION ALL
SELECT time, CONCAT(region, ' / ', cluster, ' / p99') AS series, quantiles[OFFSET(99)] AS latency_ms
FROM buckets
ORDER BY time, series;

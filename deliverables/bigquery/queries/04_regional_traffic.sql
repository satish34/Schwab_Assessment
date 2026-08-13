SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute,
  jsonPayload.region AS region,
  jsonPayload.cluster AS cluster,
  jsonPayload.service AS service,
  jsonPayload.decision AS decision,
  COUNT(*) AS request_count
FROM `PROJECT_ID.risk_logs.stdout`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
  AND resource.labels.namespace_name IN ('currency-app-a', 'currency-app-b')
  AND jsonPayload.log_type = 'request'
  AND jsonPayload.method = 'GET'
  AND (
    (resource.labels.namespace_name = 'currency-app-a'
      AND jsonPayload.service = 'app-a-gateway'
      AND jsonPayload.route = '/api/exchange-rates') OR
    (resource.labels.namespace_name = 'currency-app-b'
      AND jsonPayload.service = 'app-b-engine'
      AND jsonPayload.route = '/internal/exchange-rates')
  )
  AND jsonPayload.decision = 'RATES_RETURNED'
GROUP BY minute, region, cluster, service, decision
ORDER BY minute, region, service, decision;

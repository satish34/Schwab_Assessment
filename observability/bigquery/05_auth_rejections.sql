SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute,
  jsonPayload.region AS region,
  jsonPayload.cluster AS cluster,
  jsonPayload.service AS service,
  jsonPayload.service_version AS service_version,
  jsonPayload.decision AS decision,
  jsonPayload.error_type AS rejection_type,
  COUNT(*) AS rejection_count
FROM `PROJECT_ID.risk_logs.stdout`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
  AND jsonPayload.service = 'app-b-engine'
  AND jsonPayload.route = '/internal/exchange-rates'
  AND jsonPayload.method = 'GET'
  AND SAFE_CAST(jsonPayload.status_code AS INT64) = 401
  AND jsonPayload.decision = 'AUTH_REJECTED'
GROUP BY minute, region, cluster, service, service_version, decision, rejection_type
ORDER BY minute, region, cluster, rejection_type;

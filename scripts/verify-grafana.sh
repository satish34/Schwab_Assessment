#!/usr/bin/env bash
set -euo pipefail

mode="${1:-live}"
case "$mode" in
  --static | --sources | live) ;;
  *)
    printf 'Usage: %s [--static|--sources]\n' "$0" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_root/observability/grafana/risk-dashboard.json"
error_sql="$repo_root/observability/grafana/queries/01_error_rate_by_cell.sql"
latency_sql="$repo_root/observability/grafana/queries/02_latency_by_cell.sql"
datasources="$repo_root/observability/grafana/provisioning/datasources.yaml"
dashboard_provider="$repo_root/observability/grafana/provisioning/dashboards.yaml"

for command_name in jq rg; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required.\n' "$command_name" >&2
    exit 1
  }
done

jq -e '
  (.uid == "schwab-risk-cells")
  and (.title == "Schwab Assessment - GKE Risk Cells")
  and (.time == {"from":"now-6h","to":"now"})
  and ([.panels[].id] | sort == [1, 2, 3, 4])
  and ([.panels[].type] | all(. == "timeseries"))
  and ([.panels[].datasource.uid] | sort | unique == ["risk-bigquery", "risk-cloud-monitoring"])
  and (.panels[] | select(.id == 1) | .title == "Application error rate by cell")
  and (.panels[] | select(.id == 2) | .title == "Request latency percentiles by cell")
  and (.panels[] | select(.id == 3) | .title == "Pod restarts by cell and service")
  and (.panels[] | select(.id == 4) | .title == "CPU and memory utilization by cell and service")
  and (
    [.panels[] | .targets[] | select(.datasource.uid == "risk-bigquery")]
    | length == 2
    and all(
      (.format == 0)
      and (.editorMode == "code")
      and (.location == "US")
      and (.rawSql | contains("$__timeFilter(timestamp)"))
      and (.rawSql | contains("`schwab-assessment-gke.risk_logs.stdout`"))
      and (.rawSql | contains("jsonPayload.region"))
      and (.rawSql | contains("jsonPayload.cluster"))
    )
  )
  and (
    [.panels[] | .targets[] | select(.datasource.uid == "risk-cloud-monitoring")]
    | length == 3
    and all(
      (.queryType == "timeSeriesList")
      and (.timeSeriesList.projectName == "schwab-assessment-gke")
      and (.timeSeriesList.alignmentPeriod == "cloud-monitoring-auto")
      and (.timeSeriesList.crossSeriesReducer == "REDUCE_SUM")
      and (.timeSeriesList.groupBys == [
        "resource.label.location",
        "resource.label.cluster_name",
        "resource.label.container_name"
      ])
      and (.timeSeriesList.filters | index("risk-system") != null)
    )
  )
  and (
    [.panels[] | .targets[] | select(.datasource.uid == "risk-cloud-monitoring")
      | {
          metric: (.timeSeriesList.filters[
            (.timeSeriesList.filters | index("metric.type")) + 2
          ]),
          aligner: .timeSeriesList.perSeriesAligner
        }
    ]
    | sort_by(.metric)
    == ([
      {"metric":"kubernetes.io/container/restart_count","aligner":"ALIGN_DELTA"},
      {"metric":"kubernetes.io/container/cpu/core_usage_time","aligner":"ALIGN_RATE"},
      {"metric":"kubernetes.io/container/memory/used_bytes","aligner":"ALIGN_MEAN"}
    ] | sort_by(.metric))
  )
' "$dashboard" >/dev/null

expected_error_sql="$(tr -d '\r' <"$error_sql")"
expected_latency_sql="$(tr -d '\r' <"$latency_sql")"
dashboard_error_sql="$(jq -r '.panels[] | select(.id == 1) | .targets[0].rawSql' "$dashboard" | tr -d '\r')"
dashboard_latency_sql="$(jq -r '.panels[] | select(.id == 2) | .targets[0].rawSql' "$dashboard" | tr -d '\r')"
[[ "$dashboard_error_sql" == "$expected_error_sql" ]] || {
  printf 'The error-rate panel has drifted from its checked-in SQL.\n' >&2
  exit 1
}
[[ "$dashboard_latency_sql" == "$expected_latency_sql" ]] || {
  printf 'The latency panel has drifted from its checked-in SQL.\n' >&2
  exit 1
}

rg -q 'uid: risk-bigquery' "$datasources"
rg -q 'uid: risk-cloud-monitoring' "$datasources"
[[ "$(rg -c 'authenticationType: gce' "$datasources")" == "2" ]]
if rg -n 'authenticationType: jwt|clientEmail:|privateKeyPath:' "$datasources"; then
  printf 'Grafana provisioning must use keyless GCP metadata authentication.\n' >&2
  exit 1
fi
rg -q 'path: /var/lib/grafana/dashboards' "$dashboard_provider"

if rg -n \
  'BEGIN (RSA )?PRIVATE KEY|"private_key"|"private_key_id"|secureJsonData|Authorization:[[:space:]]*Bearer' \
  "$repo_root/observability/grafana"; then
  printf 'Grafana artifacts contain credential material or an inline secret field.\n' >&2
  exit 1
fi

printf 'Verified the four-panel Grafana dashboard, provisioning, and checked-in queries.\n'
[[ "$mode" == "--static" ]] && exit 0

for command_name in curl gcloud; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required for source-data verification.\n' "$command_name" >&2
    exit 1
  }
done

: "${PROJECT_ID:=schwab-assessment-gke}"
: "${GCLOUD_CONFIGURATION:=schwab-assessment}"
expected_account="satish.cse7@gmail.com"

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
active_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"
[[ "$active_account" == "$expected_account" && "$active_project" == "$PROJECT_ID" ]] || {
  printf 'Expected %s on project %s in gcloud configuration %s.\n' \
    "$expected_account" "$PROJECT_ID" "$GCLOUD_CONFIGURATION" >&2
  exit 1
}
[[ "$PROJECT_ID" == "schwab-assessment-gke" ]] || {
  printf 'The dashboard is frozen to project schwab-assessment-gke.\n' >&2
  exit 1
}

access_token="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" auth print-access-token
)"
[[ -n "$access_token" ]] || {
  printf 'Could not obtain a Google access token from the named configuration.\n' >&2
  exit 1
}
trap 'unset access_token' EXIT

gcp_get() {
  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    | MSYS_NO_PATHCONV=1 curl \
        --config - \
        --silent \
        --show-error \
        --fail-with-body \
        --max-time 30 \
        "$@"
}

gcp_post_json() {
  local url="$1"
  local body="$2"
  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    | MSYS_NO_PATHCONV=1 curl \
        --config - \
        --silent \
        --show-error \
        --fail-with-body \
        --max-time 30 \
        --header 'Content-Type: application/json' \
        --request POST \
        --data-binary "$body" \
        "$url"
}

end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
start_time="$(date -u -d '6 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"

verify_monitoring_metric() {
  local metric="$1"
  local aligner="$2"
  local extra_filter="${3:-}"
  local filter
  local response
  filter="metric.type=\"$metric\" AND resource.type=\"k8s_container\" AND resource.label.\"namespace_name\"=\"risk-system\"$extra_filter"
  response="$(
    gcp_get \
      --get \
      --data-urlencode "filter=$filter" \
      --data-urlencode "interval.startTime=$start_time" \
      --data-urlencode "interval.endTime=$end_time" \
      --data-urlencode 'view=FULL' \
      --data-urlencode 'pageSize=1000' \
      --data-urlencode 'aggregation.alignmentPeriod=60s' \
      --data-urlencode "aggregation.perSeriesAligner=$aligner" \
      --data-urlencode 'aggregation.crossSeriesReducer=REDUCE_SUM' \
      --data-urlencode 'aggregation.groupByFields=resource.label."location"' \
      --data-urlencode 'aggregation.groupByFields=resource.label."cluster_name"' \
      --data-urlencode 'aggregation.groupByFields=resource.label."container_name"' \
      "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/timeSeries"
  )"

  jq -e '
    [
      .timeSeries[]?
      | select((.points | length) > 0)
      | (.resource.labels.location + "/" + .resource.labels.cluster_name + "/" + .resource.labels.container_name)
    ] | sort == [
      "us-central1/gke-risk-usc1/app-a-gateway",
      "us-central1/gke-risk-usc1/app-b-engine",
      "us-east4/gke-risk-use4/app-a-gateway",
      "us-east4/gke-risk-use4/app-b-engine"
    ]
  ' <<<"$response" >/dev/null || {
    printf 'Cloud Monitoring metric %s lacks real data for a required cell or service.\n' "$metric" >&2
    exit 1
  }
}

verify_monitoring_metric 'kubernetes.io/container/restart_count' 'ALIGN_DELTA'
verify_monitoring_metric 'kubernetes.io/container/cpu/core_usage_time' 'ALIGN_RATE'
verify_monitoring_metric \
  'kubernetes.io/container/memory/used_bytes' \
  'ALIGN_MEAN' \
  ' AND metric.label."memory_type"="non-evictable"'
printf 'Verified restart, CPU, and memory source data for both services in both cells.\n'

source_query="$(cat <<'SQL'
SELECT
  jsonPayload.region AS region,
  jsonPayload.cluster AS cluster,
  COUNT(*) AS request_count,
  COUNTIF(SAFE_CAST(jsonPayload.latency_ms AS INT64) IS NOT NULL) AS latency_count
FROM `schwab-assessment-gke.risk_logs.stdout`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
  AND jsonPayload.log_type = 'request'
  AND jsonPayload.service = 'app-a-gateway'
  AND jsonPayload.route = '/v1/risk'
GROUP BY region, cluster
ORDER BY region
SQL
)"
source_payload="$(
  jq -cn --arg query "$source_query" '{
    query: $query,
    useLegacySql: false,
    location: "US",
    timeoutMs: 20000,
    maximumBytesBilled: "10485760"
  }'
)"
source_response="$(
  gcp_post_json \
    "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/queries" \
    "$source_payload"
)"
jq -e '
  (.jobComplete == true)
  and ([.rows[]? | {
    region: .f[0].v,
    cluster: .f[1].v,
    requests: (.f[2].v | tonumber),
    latency: (.f[3].v | tonumber)
  }] as $rows
    | any($rows[]; .region == "us-central1" and .cluster == "gke-risk-usc1" and .requests > 0 and .latency > 0)
    and any($rows[]; .region == "us-east4" and .cluster == "gke-risk-use4" and .requests > 0 and .latency > 0)
  )
' <<<"$source_response" >/dev/null || {
  printf 'BigQuery lacks real App A request and latency rows for both cells.\n' >&2
  exit 1
}
printf 'Verified BigQuery request and latency source rows for both cells.\n'

[[ "$mode" == "--sources" ]] && exit 0

if [[ -z "${GRAFANA_URL:-}" || -z "${GRAFANA_TOKEN:-}" ]]; then
  printf '%s\n' \
    'Grafana live gate is externally blocked: configure/import the checked-in artifacts,' \
    'then set GRAFANA_URL and a session-only GRAFANA_TOKEN and rerun make verify-grafana.' >&2
  exit 3
fi

GRAFANA_URL="${GRAFANA_URL%/}"
case "$GRAFANA_URL" in
  https://* | http://127.0.0.1:* | http://localhost:*) ;;
  *)
    printf 'GRAFANA_URL must use HTTPS, except for an explicit loopback Grafana.\n' >&2
    exit 1
    ;;
esac

grafana_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local curl_args=(
    --silent
    --show-error
    --fail-with-body
    --max-time 30
    --request "$method"
  )
  if [[ -n "$body" ]]; then
    curl_args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$GRAFANA_TOKEN" \
    | MSYS_NO_PATHCONV=1 curl --config - "${curl_args[@]}" "$GRAFANA_URL$path"
}

for datasource_uid in risk-bigquery risk-cloud-monitoring; do
  health_response="$(grafana_api GET "/api/datasources/uid/$datasource_uid/health")"
  jq -e '.status == "OK"' <<<"$health_response" >/dev/null || {
    printf 'Grafana data source %s is not healthy.\n' "$datasource_uid" >&2
    exit 1
  }
done

remote_dashboard="$(grafana_api GET '/api/dashboards/uid/schwab-risk-cells')"
jq -e '
  (.dashboard.uid == "schwab-risk-cells")
  and ([.dashboard.panels[].id] | sort == [1, 2, 3, 4])
  and ([.dashboard.panels[].datasource.uid] | sort | unique == ["risk-bigquery", "risk-cloud-monitoring"])
' <<<"$remote_dashboard" >/dev/null || {
  printf 'The canonical four-panel dashboard is not imported in Grafana.\n' >&2
  exit 1
}
remote_error_sql="$(jq -r '.dashboard.panels[] | select(.id == 1) | .targets[0].rawSql' <<<"$remote_dashboard" | tr -d '\r')"
remote_latency_sql="$(jq -r '.dashboard.panels[] | select(.id == 2) | .targets[0].rawSql' <<<"$remote_dashboard" | tr -d '\r')"
[[ "$remote_error_sql" == "$expected_error_sql" && "$remote_latency_sql" == "$expected_latency_sql" ]] || {
  printf 'The imported Grafana application queries differ from the checked-in SQL.\n' >&2
  exit 1
}
expected_monitoring_targets="$(
  jq -c '[
    .panels[]
    | select(.id == 3 or .id == 4)
    | .targets[]
    | {refId, datasource, aliasBy, queryType, timeSeriesList}
  ]' "$dashboard"
)"
remote_monitoring_targets="$(
  jq -c '[
    .dashboard.panels[]
    | select(.id == 3 or .id == 4)
    | .targets[]
    | {refId, datasource, aliasBy, queryType, timeSeriesList}
  ]' <<<"$remote_dashboard"
)"
[[ "$remote_monitoring_targets" == "$expected_monitoring_targets" ]] || {
  printf 'The imported Grafana Monitoring queries differ from the checked-in dashboard.\n' >&2
  exit 1
}

now_ms="$(( $(date -u '+%s') * 1000 ))"
from_ms="$(( now_ms - 21600000 ))"
for panel_id in 1 2 3 4; do
  panel_payload="$(
    jq -c \
      --arg from "$from_ms" \
      --arg to "$now_ms" \
      --argjson panel_id "$panel_id" \
      '{
        from: $from,
        to: $to,
        queries: [
          .panels[]
          | select(.id == $panel_id)
          | .targets[]
          | . + {
              intervalMs: (.intervalMs // 60000),
              maxDataPoints: 360
            }
        ]
      }' "$dashboard"
  )"
  panel_response="$(grafana_api POST '/api/ds/query' "$panel_payload")"
  expected_refs="$(
    jq -c --argjson panel_id "$panel_id" '[
      .panels[] | select(.id == $panel_id) | .targets[].refId
    ] | sort' "$dashboard"
  )"
  jq -e --argjson expected_refs "$expected_refs" '
    ((.results | keys | sort) == $expected_refs)
    and all(
      .results[];
      ((.status // 200) == 200)
      and ((.error // "") == "")
      and ([.frames[]?.data.values[]?[]? | select(. != null)] | length > 0)
      and ([.. | strings] | any(contains("us-central1")))
      and ([.. | strings] | any(contains("us-east4")))
    )
  ' <<<"$panel_response" >/dev/null || {
    printf 'Grafana panel %s lacks a target result, real data, or one of the two cells.\n' "$panel_id" >&2
    exit 1
  }
done

printf 'Grafana gate passed: all four canonical panels returned real data from both cells.\n'

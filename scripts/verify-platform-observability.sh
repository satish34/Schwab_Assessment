#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
metrics_lookback_seconds="${PLATFORM_METRICS_LOOKBACK_SECONDS:-21600}"
hpa_lookback_seconds="${HPA_METRIC_LOOKBACK_SECONDS:-604800}"
log_freshness="${PLATFORM_LOG_FRESHNESS:-6h}"
access_token=""

fail() {
  printf 'verify-platform-observability: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  unset access_token GOOGLE_OAUTH_ACCESS_TOKEN
}
trap cleanup EXIT INT TERM

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project, received $PROJECT_ID"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"
[[ "$metrics_lookback_seconds" =~ ^[0-9]+$ ]] \
  && ((metrics_lookback_seconds >= 900 && metrics_lookback_seconds <= 604800)) \
  || fail "PLATFORM_METRICS_LOOKBACK_SECONDS must be 900..604800"
[[ "$hpa_lookback_seconds" =~ ^[0-9]+$ ]] \
  && ((hpa_lookback_seconds >= 3600 && hpa_lookback_seconds <= 1209600)) \
  || fail "HPA_METRIC_LOOKBACK_SECONDS must be 3600..1209600"
[[ "$log_freshness" =~ ^[1-9][0-9]*[mhd]$ ]] \
  || fail "PLATFORM_LOG_FRESHNESS must be an integer followed by m, h, or d"

for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_ACCESS_TOKEN GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_KEYFILE_JSON \
  GOOGLE_CREDENTIALS GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] || fail "$override_name must be unset"
done

for command_name in curl date gcloud jq timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
for auth_property in \
  auth/access_token_file auth/credential_file_override \
  auth/impersonate_service_account; do
  auth_value="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value "$auth_property" 2>/dev/null)"
  [[ -z "$auth_value" || "$auth_value" == "(unset)" ]] \
    || fail "$auth_property must be unset in the named gcloud configuration"
done
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected gcloud account $expected_account, found ${active_account:-<none>}"
configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected gcloud project $PROJECT_ID, found ${configured_project:-<none>}"

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

gcloud_json() {
  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    "$@" --format=json
}

access_token="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" auth print-access-token
)"
[[ -n "$access_token" ]] || fail "could not obtain a short-lived access token"

api_get() {
  local url="$1"
  shift

  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    | timeout --foreground --signal=INT 2m \
      curl --silent --show-error --fail --config - --get "$@" "$url"
}

api_post_json() {
  local url="$1"
  local body="$2"

  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    | timeout --foreground --signal=INT 2m \
      curl --silent --show-error --fail --config - \
        --header 'Content-Type: application/json' \
        --request POST --data-binary "$body" "$url"
}

monitoring_series() {
  local filter="$1"
  local lookback_seconds="$2"
  local end_time
  local start_time

  end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  start_time="$(date -u -d "$lookback_seconds seconds ago" '+%Y-%m-%dT%H:%M:%SZ')"
  api_get "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/timeSeries" \
    --data-urlencode "filter=$filter" \
    --data-urlencode "interval.startTime=$start_time" \
    --data-urlencode "interval.endTime=$end_time" \
    --data-urlencode 'view=FULL' \
    --data-urlencode 'pageSize=1000'
}

verify_metric_descriptor() {
  local metric="$1"
  local kind="$2"
  local value_type="$3"
  local resource_type="$4"
  shift 4
  local expected_labels_json
  local descriptor_json

  expected_labels_json="$(printf '%s\n' "$@" | jq -R . | jq -s 'sort')"
  descriptor_json="$(
    api_get "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/metricDescriptors/$metric"
  )"
  jq -e \
    --arg metric "$metric" \
    --arg kind "$kind" \
    --arg value_type "$value_type" \
    --arg resource_type "$resource_type" \
    --argjson expected_labels "$expected_labels_json" '
      (.type == $metric)
      and (.metricKind == $kind)
      and (.valueType == $value_type)
      and (.monitoredResourceTypes == [$resource_type])
      and (([.labels[].key] | sort) == $expected_labels)
    ' <<<"$descriptor_json" >/dev/null \
    || fail "metric descriptor $metric does not match its exact contract"
}

expected_logging_components='[
  "APISERVER",
  "CONTROLLER_MANAGER",
  "KCP_HPA",
  "SCHEDULER",
  "SYSTEM_COMPONENTS",
  "WORKLOADS"
]'
for cluster_spec in \
  'gke-risk-usc1 us-central1' \
  'gke-risk-use4 us-east4'; do
  read -r cluster region <<<"$cluster_spec"
  cluster_json="$(
    gcloud_json container clusters describe "$cluster" --location="$region"
  )"
  jq -e \
    --arg cluster "$cluster" \
    --arg region "$region" \
    --argjson components "$expected_logging_components" '
      (.name == $cluster)
      and (.location == $region)
      and (.status == "RUNNING")
      and ((.loggingConfig.componentConfig.enableComponents | sort) == $components)
      and ((.monitoringConfig.componentConfig.enableComponents | sort)
        == ["SYSTEM_COMPONENTS"])
    ' <<<"$cluster_json" >/dev/null \
    || fail "$cluster does not expose the exact low-cost logging and monitoring components"
done

for subnet_spec in \
  'risk-usc1 us-central1' \
  'risk-use4 us-east4'; do
  read -r subnet region <<<"$subnet_spec"
  subnet_json="$(
    gcloud_json compute networks subnets describe "$subnet" --region="$region"
  )"
  jq -e \
    --arg subnet "$subnet" '
      (.name == $subnet)
      and (.logConfig.enable == true)
      and (.logConfig.aggregationInterval == "INTERVAL_1_MIN")
      and (.logConfig.flowSampling == 0.05)
      and (.logConfig.metadata == "EXCLUDE_ALL_METADATA")
    ' <<<"$subnet_json" >/dev/null \
    || fail "$subnet does not use the exact 5% one-minute VPC Flow Logs contract"
done

backend_json="$(
  gcloud_json compute backend-services describe \
    risk-app-a-gateway-backend --global
)"
jq -e '
  (.name == "risk-app-a-gateway-backend")
  and (.logConfig.enable == true)
  and (
    if ((.securityPolicy // "") | length) > 0 then
      (.securityPolicy | endswith("/global/securityPolicies/currency-edge-waf"))
      and (.logConfig.sampleRate == 1)
    else
      (.logConfig.sampleRate == 0.05)
    end
  )
' <<<"$backend_json" >/dev/null \
  || fail "the backend service does not use the exact conditional request-log sample"

sink_json="$(
  gcloud_json logging sinks describe currency-platform-to-bigquery
)"
sink_writer="$(jq -r '.writerIdentity // ""' <<<"$sink_json")"
jq -e \
  --arg destination \
    "bigquery.googleapis.com/projects/$PROJECT_ID/datasets/currency_platform_logs" '
    (.destination == $destination)
    and (.bigqueryOptions.usePartitionedTables == true)
    and (.writerIdentity | startswith("serviceAccount:"))
    and (.filter | contains("resource.type=\"k8s_control_plane_component\""))
    and (.filter | contains("resource.type=\"k8s_node\""))
    and (.filter | contains("NOT (log_id(\"stdout\") OR log_id(\"stderr\"))"))
    and (.filter | contains("sample(insertId, 0.10)"))
    and (.filter | contains("resource.type=\"http_load_balancer\""))
    and (.filter | contains("log_id(\"requests\")"))
    and (.filter | contains("log_id(\"compute.googleapis.com/vpc_flows\")"))
    and (.filter | contains("log_id(\"compute.googleapis.com/firewall\")"))
    and (.filter | contains("log_id(\"compute.googleapis.com/healthchecks\")"))
  ' <<<"$sink_json" >/dev/null \
  || fail "the bounded platform BigQuery sink does not match its exact filter contract"

dataset_json="$(
  api_get "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/datasets/currency_platform_logs"
)"
jq -e \
  --arg project "$PROJECT_ID" \
  --arg writer "$sink_writer" '
    (.datasetReference == {
      "datasetId": "currency_platform_logs",
      "projectId": $project
    })
    and (.location == "US")
    and (.defaultPartitionExpirationMs == "2592000000")
    and (.maxTimeTravelHours == "48")
    and ([
      .access[]?
      | select(
          (.role == "WRITER" or .role == "roles/bigquery.dataEditor")
          and (
            .iamMember == $writer
            or ("serviceAccount:" + (.userByEmail // "")) == $writer
          )
        )
    ] | length == 1)
  ' <<<"$dataset_json" >/dev/null \
  || fail "the platform dataset retention or sink-writer access is invalid"

# The sink configuration alone does not prove delivery. Query only the
# partition-pruned HTTPS request table, cap every attempt at 100 MiB, and retain
# only a count/timestamp summary. The bounded poll allows for normal sink lag
# immediately after the platform expansion is applied.
platform_query_cap=104857600
platform_table_names="$(
  api_get \
    "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/datasets/currency_platform_logs/tables" \
    --data-urlencode 'maxResults=1000' \
    --data-urlencode 'fields=tables(tableReference),nextPageToken'
)"
jq -e '
  ((.nextPageToken // "") == "")
  and ([.tables[]?.tableReference.tableId] | index("requests") != null)
' <<<"$platform_table_names" >/dev/null \
  || fail "the platform dataset does not contain the expected requests sink table"

platform_query="$(cat <<'SQL'
SELECT
  COUNT(*) AS fresh_rows,
  FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MAX(timestamp), 'UTC') AS latest_timestamp
FROM `schwab-assessment-gke.currency_platform_logs.requests`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
  AND resource.type = 'http_load_balancer'
  AND resource.labels.backend_target_name = 'risk-app-a-gateway-backend'
  AND ENDS_WITH(logName, '/logs/requests')
  AND httpRequest.requestUrl LIKE 'https://satish.store/%'
SQL
)"
platform_query_payload="$(
  jq -cn \
    --arg query "$platform_query" \
    --arg maximum_bytes_billed "$platform_query_cap" '
      {
        query: $query,
        useLegacySql: false,
        useQueryCache: false,
        location: "US",
        timeoutMs: 30000,
        maximumBytesBilled: $maximum_bytes_billed
      }
    '
)"
platform_delivery=""
for _ in $(seq 1 30); do
  if platform_query_response="$(
    api_post_json \
      "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/queries" \
      "$platform_query_payload"
  )" && jq -e --argjson byte_cap "$platform_query_cap" '
      (.jobComplete == true)
      and (((.errors // []) | length) == 0)
      and (((.totalBytesProcessed // "0") | tonumber) <= $byte_cap)
      and ((.rows // []) | length == 1)
      and ((.rows[0].f[0].v | tonumber) > 0)
      and ((.rows[0].f[1].v // "")
        | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' <<<"$platform_query_response" >/dev/null 2>&1; then
    platform_delivery="$(
      jq -c --argjson byte_cap "$platform_query_cap" '
        {
          table: "currency_platform_logs.requests",
          resource_type: "http_load_balancer",
          backend: "risk-app-a-gateway-backend",
          endpoint: "https://satish.store/",
          freshness: "6h",
          fresh_rows: (.rows[0].f[0].v | tonumber),
          latest_timestamp: .rows[0].f[1].v,
          bytes_processed: ((.totalBytesProcessed // "0") | tonumber),
          maximum_bytes_billed: $byte_cap
        }
      ' <<<"$platform_query_response"
    )"
    break
  fi
  sleep 10
done
[[ -n "$platform_delivery" ]] \
  || fail "no fresh load-balancer row reached the bounded platform BigQuery sink within five minutes"
printf 'platform_bigquery_delivery=%s\n' "$platform_delivery"
unset platform_table_names platform_query platform_query_payload platform_query_response

assert_log_activity() {
  local label="$1"
  local filter="$2"
  local logs_json
  local summary

  logs_json="$(
    gcloud_json logging read "$filter" \
      --freshness="$log_freshness" --limit=1 --order=desc
  )"
  jq -e 'length == 1' <<<"$logs_json" >/dev/null \
    || fail "no $label log arrived within $log_freshness"
  summary="$(
    jq -c '.[0] | {
      timestamp,
      resource_type: .resource.type,
      log_id: (.logName | split("/")[-1])
    }' <<<"$logs_json"
  )"
  printf 'log_activity=%s %s\n' "$label" "$summary"
}

assert_log_activity control_plane \
  'resource.type="k8s_control_plane_component" AND resource.labels.cluster_name=("gke-risk-usc1" OR "gke-risk-use4")'
assert_log_activity node \
  'resource.type="k8s_node" AND resource.labels.cluster_name=("gke-risk-usc1" OR "gke-risk-use4")'
assert_log_activity hpa_decision \
  'log_id("container.googleapis.com/hpa-controller") AND resource.labels.cluster_name=("gke-risk-usc1" OR "gke-risk-use4")'
assert_log_activity load_balancer \
  'resource.type="http_load_balancer" AND log_id("requests") AND resource.labels.backend_target_name="risk-app-a-gateway-backend"'
assert_log_activity vpc_flow \
  'log_id("compute.googleapis.com/vpc_flows") AND resource.labels.subnetwork_name=("risk-usc1" OR "risk-use4")'
assert_log_activity firewall \
  'log_id("compute.googleapis.com/firewall")'

verify_metric_descriptor \
  kubernetes.io/node/status_condition GAUGE BOOL k8s_node \
  condition status
verify_metric_descriptor \
  kubernetes.io/autoscaler/latencies/per_hpa_recommendation_scale_latency_seconds \
  GAUGE DOUBLE k8s_scale metric_type
verify_metric_descriptor \
  loadbalancing.googleapis.com/https/request_count DELTA INT64 https_lb_rule \
  cache_result client_country load_balancing_scheme protocol \
  proxy_continent response_code response_code_class
verify_metric_descriptor \
  loadbalancing.googleapis.com/https/total_latencies \
  DELTA DISTRIBUTION https_lb_rule \
  cache_result client_country load_balancing_scheme protocol \
  proxy_continent response_code response_code_class

node_series="$(
  monitoring_series \
    'metric.type="kubernetes.io/node/status_condition" AND resource.type="k8s_node" AND metric.labels.condition="Ready"' \
    1200
)"
node_summary="$(
  jq -c '
    [.timeSeries[]?
      | select((.points | length) > 0)
      | {
          cluster: .resource.labels.cluster_name,
          node: .resource.labels.node_name,
          status: .metric.labels.status,
          active: (.points[0].value.boolValue == true)
        }
      | select(.cluster == "gke-risk-usc1" or .cluster == "gke-risk-use4")
    ]
    | group_by(.cluster)
    | map({
        cluster: .[0].cluster,
        ready_nodes: ([.[] | select(.status == "True" and .active) | .node]
          | unique | length),
        unhealthy_nodes: ([.[]
          | select((.status == "False" or .status == "Unknown") and .active)
          | .node] | unique | length)
      })
    | sort_by(.cluster)
  ' <<<"$node_series"
)"
jq -e '
  (map(.cluster) == ["gke-risk-usc1", "gke-risk-use4"])
  and all(.[]; .ready_nodes > 0 and .unhealthy_nodes == 0)
' <<<"$node_summary" >/dev/null \
  || fail "Cloud Monitoring does not show current Ready nodes in both cells"
printf 'node_health=%s\n' "$node_summary"

hpa_series="$(
  monitoring_series \
    'metric.type="kubernetes.io/autoscaler/latencies/per_hpa_recommendation_scale_latency_seconds" AND resource.type="k8s_scale"' \
    "$hpa_lookback_seconds"
)"
hpa_summary="$(
  jq -c '
    [.timeSeries[]?
      | select((.points | length) > 0)
      | select(
          .resource.labels.namespace_name == "currency-app-a"
          or .resource.labels.namespace_name == "currency-app-b"
        )
      | {
          cluster: .resource.labels.cluster_name,
          namespace: .resource.labels.namespace_name,
          controller: .resource.labels.controller_name,
          events: (.points | length),
          latest: .points[0].interval.endTime
        }
    ]
  ' <<<"$hpa_series"
)"
printf 'hpa_scale_latency=%s\n' "$hpa_summary"
printf '%s\n' \
  'hpa_event_gate=KCP_HPA decision logs are required; a zero scale-latency series means no replica-count change occurred in the lookback.'

lb_filter_suffix='resource.type="https_lb_rule" AND resource.labels.backend_target_name="risk-app-a-gateway-backend" AND resource.labels.forwarding_rule_name="risk-app-a-https"'
request_series="$(
  monitoring_series \
    "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND $lb_filter_suffix" \
    "$metrics_lookback_seconds"
)"
latency_series="$(
  monitoring_series \
    "metric.type=\"loadbalancing.googleapis.com/https/total_latencies\" AND $lb_filter_suffix" \
    "$metrics_lookback_seconds"
)"
lb_summary="$(
  jq -cn \
    --argjson requests "$request_series" \
    --argjson latencies "$latency_series" '
      {
        request_series: (($requests.timeSeries // []) | length),
        request_points: ([$requests.timeSeries[]?.points | length] | add // 0),
        five_xx_series: ([$requests.timeSeries[]?
          | select(.metric.labels.response_code_class == "500")] | length),
        latency_series: (($latencies.timeSeries // []) | length),
        latency_points: ([$latencies.timeSeries[]?.points | length] | add // 0)
      }
    '
)"
jq -e '
  (.request_series > 0)
  and (.request_points > 0)
  and (.latency_series > 0)
  and (.latency_points > 0)
' <<<"$lb_summary" >/dev/null \
  || fail "Cloud Monitoring has no recent request-volume or latency points for the HTTPS load balancer"
printf 'load_balancer_metrics=%s\n' "$lb_summary"
printf '%s\n' \
  'Verified bounded platform logging plus current node health, HPA decision events, and HTTPS request/5xx/latency metric coverage.'

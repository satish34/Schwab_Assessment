#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
expected_bq_image="gcr.io/google.com/cloudsdktool/google-cloud-cli:525.0.0-slim"
dataset="risk_logs"
table="stdout"
runtime_dir="$repo_root/.tmp"
manifest="$runtime_dir/bigquery-seed.json"
results_dir="$runtime_dir/bigquery-gate"
export_timeout_seconds="${BQ_EXPORT_TIMEOUT_SECONDS:-900}"
poll_seconds="${BQ_POLL_SECONDS:-15}"
query_timeout_seconds="${BQ_QUERY_TIMEOUT_SECONDS:-180}"
maximum_bytes_billed="${BQ_MAXIMUM_BYTES_BILLED:-1000000000}"
seed_max_age_seconds="${BQ_SEED_MAX_AGE_SECONDS:-3600}"
work_dir=""
sql_files=("$repo_root"/observability/bigquery/0[1-5]_*.sql)

fail() {
  printf 'verify-bigquery: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  trap - EXIT INT TERM
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/verify-bigquery.*)
        rm -f -- "$work_dir"/*
        rmdir -- "$work_dir" 2>/dev/null || true
        ;;
    esac
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s FULL_GIT_SHA\n' "$0" >&2
  exit 2
fi

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
: "${GCLOUD_IMAGE:?GCLOUD_IMAGE is required}"

git_sha="$1"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project, received $PROJECT_ID"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"
[[ "$GCLOUD_IMAGE" == "$expected_bq_image" ]] \
  || fail "GCLOUD_IMAGE must remain pinned to $expected_bq_image"
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "the image version must be one full lowercase 40-character Git SHA"
[[ "$export_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((export_timeout_seconds >= 60 && export_timeout_seconds <= 1800)) \
  || fail "BQ_EXPORT_TIMEOUT_SECONDS must be between 60 and 1800"
[[ "$poll_seconds" =~ ^[0-9]+$ ]] \
  && ((poll_seconds >= 5 && poll_seconds <= 60)) \
  || fail "BQ_POLL_SECONDS must be between 5 and 60"
[[ "$query_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((query_timeout_seconds >= 30 && query_timeout_seconds <= 600)) \
  || fail "BQ_QUERY_TIMEOUT_SECONDS must be between 30 and 600"
[[ "$maximum_bytes_billed" =~ ^[0-9]+$ ]] \
  && ((maximum_bytes_billed >= 10000000 && maximum_bytes_billed <= 10000000000)) \
  || fail "BQ_MAXIMUM_BYTES_BILLED must be between 10000000 and 10000000000"
[[ "$seed_max_age_seconds" =~ ^[0-9]+$ ]] \
  && ((seed_max_age_seconds >= 300 && seed_max_age_seconds <= 21600)) \
  || fail "BQ_SEED_MAX_AGE_SECONDS must be between 300 and 21600"

for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] \
    || fail "$override_name must be unset so the named gcloud account is authoritative"
done

for command_name in docker gcloud git jq sed terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
[[ "${#sql_files[@]}" == "5" ]] \
  || fail "exactly five checked-in BigQuery queries are required"
for sql_file in "${sql_files[@]}"; do
  [[ -f "$sql_file" ]] || fail "a checked-in BigQuery query is missing"
done
[[ -f "$manifest" ]] \
  || fail "the current traffic manifest is missing; run make seed-traffic first"
git cat-file -e "$git_sha^{commit}" 2>/dev/null \
  || fail "Git SHA $git_sha is not a commit in this repository"

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected gcloud account $expected_account, found ${active_account:-<none>}"
configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected gcloud project $PROJECT_ID, found ${configured_project:-<none>}"
for auth_property in \
  auth/access_token_file auth/credential_file_override \
  auth/impersonate_service_account; do
  [[ -z "$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value "$auth_property" 2>/dev/null)" ]] \
    || fail "$auth_property must be unset in the named gcloud configuration"
done

lb_outputs="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    terraform -chdir=infra/30-lb output -json
)"
public_endpoint="$(jq -r '.public_endpoint.value // ""' <<<"$lb_outputs")"

jq -e \
  --arg project "$PROJECT_ID" \
  --arg configuration "$GCLOUD_CONFIGURATION" \
  --arg image_sha "$git_sha" \
  --arg endpoint "$public_endpoint" \
  --argjson max_age "$seed_max_age_seconds" '
    (.schema_version == 2) and
    (.project_id == $project) and
    (.gcloud_configuration == $configuration) and
    (.image_sha == $image_sha) and
    (.public_endpoint == $endpoint) and
    (.run_id | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.started_at | fromdateiso8601) <= (.completed_at | fromdateiso8601) and
    (.completed_at | fromdateiso8601) >= (now - $max_age) and
    (.success_traffic_duration_seconds >= 300) and
    (.events | length) >= 20 and
    ([.events[].correlation_id] | length == (unique | length)) and
    ([.events[].trace_id] | length == (unique | length)) and
    all(.events[];
      (.path == "global" or .path == "cell") and
      (.target_service == "app-a-gateway" or
       .target_service == "app-b-engine") and
      (.kind == "success" or .kind == "controlled_error") and
      (.region == "us-central1" or .region == "us-east4") and
      ((.region == "us-central1" and .cluster == "gke-risk-usc1") or
       (.region == "us-east4" and .cluster == "gke-risk-use4")) and
      (.correlation_id | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
      (.trace_id | test("^[0-9a-f]{32}$")) and
      ((.kind == "success" and .http_status == 200 and
        .decision == "RATES_RETURNED") or
       (.kind == "controlled_error" and .http_status >= 500 and
        .decision == "")))
  ' "$manifest" >/dev/null \
  || fail "the traffic manifest does not match the current immutable edge"

jq -e '
  .events as $events |
  any($events[];
    .path == "global" and .kind == "success" and
    .decision == "RATES_RETURNED") and
  (["us-central1", "us-east4"] | all(.[];
    . as $region |
    any($events[];
      .path == "cell" and .target_service == "app-a-gateway" and
      .kind == "success" and .region == $region and
      .decision == "RATES_RETURNED") and
    any($events[];
      .path == "cell" and .target_service == "app-a-gateway" and
      .kind == "controlled_error" and .region == $region) and
    any($events[];
      .path == "cell" and .target_service == "app-b-engine" and
      .kind == "controlled_error" and .region == $region)))
' "$manifest" >/dev/null \
  || fail "the traffic manifest lacks an exchange-rate success or controlled-error cell"

mkdir -p "$runtime_dir" "$results_dir"
git check-ignore --quiet -- "$results_dir" \
  || fail "the BigQuery result path is not ignored by Git"
work_dir="$(mktemp -d "$runtime_dir/verify-bigquery.XXXXXX")"

CLOUDSDK_AUTH_ACCESS_TOKEN="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      auth print-access-token
)"
export CLOUDSDK_AUTH_ACCESS_TOKEN
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

bq_command() {
  timeout --foreground --signal=INT --kill-after=10s \
    "${query_timeout_seconds}s" \
    docker run --rm --interactive \
      --env CLOUDSDK_AUTH_ACCESS_TOKEN \
      --env CLOUDSDK_CORE_PROJECT \
      "$GCLOUD_IMAGE" bq --quiet=true --project_id="$PROJECT_ID" \
      --location=US "$@"
}

bq_query() {
  bq_command query --use_legacy_sql=false --use_cache=false \
    --maximum_bytes_billed="$maximum_bytes_billed" --max_rows=10000 \
    --format=prettyjson
}

table_list_file="$work_dir/tables.json"
table_list_error="$work_dir/tables.err"
deadline=$((SECONDS + export_timeout_seconds))
table_found=false
while ((SECONDS < deadline)); do
  if bq_command ls --format=prettyjson "$PROJECT_ID:$dataset" \
      >"$table_list_file" 2>"$table_list_error" \
    && jq -e --arg table "$table" '
      any(.[]; .tableReference.tableId == $table)
    ' "$table_list_file" >/dev/null 2>&1; then
    table_found=true
    break
  fi
  sleep "$poll_seconds"
done
[[ "$table_found" == true ]] \
  || {
    cat "$table_list_error" >&2
    fail "$PROJECT_ID.$dataset.$table was not created within ${export_timeout_seconds}s"
  }

table_metadata="$work_dir/table-metadata.json"
bq_command show --format=prettyjson "$PROJECT_ID:$dataset.$table" \
  >"$table_metadata"
jq -e \
  --arg project "$PROJECT_ID" \
  --arg dataset "$dataset" \
  --arg table "$table" '
    (.tableReference == {
      projectId: $project,
      datasetId: $dataset,
      tableId: $table
    }) and
    (.location == "US") and
    (.timePartitioning.type == "DAY") and
    (.timePartitioning.field == "timestamp") and
    (.schema.fields as $fields |
      any($fields[]; .name == "timestamp" and .type == "TIMESTAMP") and
      ([ $fields[] | select(.name == "jsonPayload") | .fields ][0] as $json |
        any($json[]; .name == "service" and .type == "STRING") and
        any($json[]; .name == "service_version" and .type == "STRING") and
        any($json[]; .name == "region" and .type == "STRING") and
        any($json[]; .name == "cluster" and .type == "STRING") and
        any($json[]; .name == "correlation_id" and .type == "STRING") and
        any($json[]; .name == "trace_id" and .type == "STRING") and
        any($json[]; .name == "route" and .type == "STRING") and
        any($json[]; .name == "method" and .type == "STRING") and
        any($json[]; .name == "decision" and .type == "STRING") and
        any($json[]; .name == "status_code" and .type == "FLOAT") and
        any($json[]; .name == "latency_ms" and .type == "FLOAT") and
        any($json[]; .name == "is_test" and .type == "BOOLEAN")))
' "$table_metadata" >/dev/null \
  || fail "the stdout table is not the expected partitioned, type-stable schema"

started_at="$(jq -r '.started_at' "$manifest")"
expected_rows=""
while IFS=$'\t' read -r correlation_id trace_id target_service kind region cluster decision http_status; do
  row="STRUCT('$correlation_id' AS correlation_id, '$trace_id' AS trace_id, '$target_service' AS target_service, '$kind' AS kind, '$region' AS region, '$cluster' AS cluster, '$decision' AS decision, $http_status AS http_status)"
  expected_rows+="${expected_rows:+,}$row"
done < <(
  jq -r '.events[] | [
    .correlation_id, .trace_id, .target_service, .kind,
    .region, .cluster,
    (if .decision == "" then "__NONE__" else .decision end),
    (.http_status | tostring)
  ] | @tsv' "$manifest"
)

scope_sql="$work_dir/current-seed.sql"
printf '%s\n' \
  'WITH expected AS (' \
  "  SELECT * FROM UNNEST([$expected_rows])" \
  '),' \
  'logs AS (' \
  '  SELECT' \
  '    jsonPayload.correlation_id AS correlation_id,' \
  '    jsonPayload.trace_id AS trace_id,' \
  '    jsonPayload.service AS service,' \
  '    jsonPayload.service_version AS service_version,' \
  '    jsonPayload.region AS region,' \
  '    jsonPayload.cluster AS cluster,' \
  '    jsonPayload.route AS route,' \
  '    jsonPayload.method AS method,' \
  '    jsonPayload.decision AS decision,' \
  '    SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code,' \
  '    SAFE_CAST(jsonPayload.latency_ms AS INT64) AS latency_ms,' \
  '    SAFE_CAST(jsonPayload.is_test AS BOOL) AS is_test' \
  "  FROM \`$PROJECT_ID.$dataset.$table\`" \
  "  WHERE timestamp >= TIMESTAMP('$started_at') - INTERVAL 2 MINUTE" \
  '    AND timestamp <= CURRENT_TIMESTAMP()' \
  "    AND jsonPayload.log_type = 'request'" \
  '    AND jsonPayload.correlation_id IN (' \
  '      SELECT correlation_id FROM expected' \
  '    )' \
  ')' \
  'SELECT' \
  '  e.correlation_id,' \
  '  e.target_service,' \
  '  e.kind,' \
  '  COUNTIF(' \
  '    l.service = e.target_service AND' \
  '    l.service_version = '"'"$git_sha"'"' AND' \
  '    l.region = e.region AND l.cluster = e.cluster AND' \
  '    l.method = '"'"GET"'"' AND' \
  '    ((e.target_service = '"'"app-a-gateway"'"' AND l.route = '"'"/api/exchange-rates"'"') OR' \
  '     (e.target_service = '"'"app-b-engine"'"' AND l.route = '"'"/internal/exchange-rates"'"')) AND' \
  '    l.trace_id = e.trace_id AND l.latency_ms >= 0 AND' \
  '    l.is_test = FALSE AND' \
  '    ((e.kind = '"'"success"'"' AND l.status_code = 200 AND' \
  '      l.decision = e.decision) OR' \
  '     (e.kind = '"'"controlled_error"'"' AND l.status_code >= 500))' \
  '  ) AS target_rows,' \
  '  COUNTIF(' \
  '    l.service = '"'"app-a-gateway"'"' AND l.service_version = '"'"$git_sha"'"' AND' \
  '    l.region = e.region AND l.cluster = e.cluster AND' \
  '    l.route = '"'"/api/exchange-rates"'"' AND l.method = '"'"GET"'"' AND' \
  '    l.trace_id = e.trace_id AND l.status_code = 200 AND' \
  '    l.decision = e.decision AND l.latency_ms >= 0 AND l.is_test = FALSE' \
  '  ) AS app_a_success_rows,' \
  '  COUNTIF(' \
  '    l.service = '"'"app-b-engine"'"' AND l.service_version = '"'"$git_sha"'"' AND' \
  '    l.region = e.region AND l.cluster = e.cluster AND' \
  '    l.route = '"'"/internal/exchange-rates"'"' AND l.method = '"'"GET"'"' AND' \
  '    l.trace_id = e.trace_id AND l.status_code = 200 AND' \
  '    l.decision = e.decision AND l.latency_ms >= 0 AND l.is_test = FALSE' \
  '  ) AS app_b_success_rows' \
  'FROM expected AS e' \
  'LEFT JOIN logs AS l USING (correlation_id)' \
  'GROUP BY e.correlation_id, e.target_service, e.kind' \
  'ORDER BY e.correlation_id;' \
  >"$scope_sql"

scope_result="$work_dir/current-seed.json"
scope_error="$work_dir/current-seed.err"
seed_rows_ready=false
while ((SECONDS < deadline)); do
  if bq_query <"$scope_sql" >"$scope_result" 2>"$scope_error" \
    && jq -e --argjson expected "$(jq '.events | length' "$manifest")" '
      (length == $expected) and
      all(.[];
        ((.target_rows | tonumber) >= 1) and
        (if .kind == "success" and .target_service == "app-a-gateway"
         then ((.app_a_success_rows | tonumber) >= 1 and
               (.app_b_success_rows | tonumber) >= 1)
         else true
         end))
    ' "$scope_result" >/dev/null 2>&1; then
    seed_rows_ready=true
    break
  fi
  sleep "$poll_seconds"
done
[[ "$seed_rows_ready" == true ]] \
  || {
    cat "$scope_error" >&2
    fail "current immutable seed rows did not fully export within ${export_timeout_seconds}s"
  }

# Refresh the inventory after ingestion so a newly created error table cannot
# be missed by the earlier table-existence poll.
bq_command ls --format=prettyjson "$PROJECT_ID:$dataset" \
  >"$table_list_file"
export_error_count=0
if jq -e '
    any(.[]; .tableReference.tableId == "export_errors")
  ' "$table_list_file" >/dev/null; then
  export_errors_sql="$work_dir/export-errors.sql"
  printf '%s\n' \
    'SELECT COUNT(*) AS error_count' \
    "FROM \`$PROJECT_ID.$dataset.export_errors\`" \
    "WHERE timestamp >= TIMESTAMP('$started_at') - INTERVAL 2 MINUTE;" \
    >"$export_errors_sql"
  bq_query <"$export_errors_sql" >"$work_dir/export-errors.json"
  export_error_count="$(jq -r '.[0].error_count // "-1"' "$work_dir/export-errors.json")"
fi
[[ "$export_error_count" == "0" ]] \
  || fail "risk_logs.export_errors contains $export_error_count current-run schema errors"

query_index=0
for sql_file in "${sql_files[@]}"; do
  query_index=$((query_index + 1))
  query_name="$(basename "$sql_file" .sql)"
  rendered_sql="$work_dir/$query_name.sql"
  query_result="$work_dir/$query_name.json"
  sed "s/PROJECT_ID/$PROJECT_ID/g" "$sql_file" >"$rendered_sql"
  ! grep -q 'PROJECT_ID' "$rendered_sql" \
    || fail "$query_name still contains the project placeholder"
  bq_query <"$rendered_sql" >"$query_result"

  case "$query_index" in
    1)
      jq -e '
        length > 0 and
        (map(.request_count | tonumber) | add) > 0 and
        (map(.error_count | tonumber) | add) >= 2 and
        all(.[];
          (.request_count | tonumber) > 0 and
          (.error_count | tonumber) >= 0 and
          (.error_rate_pct | tonumber) >= 0 and
          (.error_rate_pct | tonumber) <= 100)
      ' "$query_result" >/dev/null \
        || fail "$query_name did not return substantive success/error traffic"
      ;;
    2)
      jq -e '
        length > 0 and
        all(.[];
          (.p50_ms | tonumber) >= 0 and
          (.p95_ms | tonumber) >= (.p50_ms | tonumber) and
          (.p99_ms | tonumber) >= (.p95_ms | tonumber))
      ' "$query_result" >/dev/null \
        || fail "$query_name did not return ordered, numeric latency percentiles"
      ;;
    3)
      jq -e '
        length > 0 and
        ([.[].region] | unique | sort) == ["us-central1", "us-east4"] and
        all(.[];
          (.trace_id | test("^[0-9a-f]{32}$")) and
          (.correlation_id | test("^[0-9a-f-]{36}$")) and
          ((.region == "us-central1" and .cluster == "gke-risk-usc1") or
           (.region == "us-east4" and .cluster == "gke-risk-use4")) and
          (.app_a_status | tonumber) >= 200 and
          (.app_b_status | tonumber) >= 200 and
          (.app_a_latency_ms | tonumber) >= 0 and
          (.app_b_latency_ms | tonumber) >= 0)
      ' "$query_result" >/dev/null \
        || fail "$query_name did not prove two-region App A/App B trace joins"
      ;;
    4)
      jq -e '
        . as $rows |
        (["us-central1", "us-east4"] |
          all(.[];
            . as $region |
            (["app-a-gateway", "app-b-engine"] |
              all(.[];
                . as $service |
                any($rows[];
                  .region == $region and .service == $service and
                  .decision == "RATES_RETURNED" and
                  (.request_count | tonumber) > 0
                )
              )
            )
          )
        )
      ' "$query_result" >/dev/null \
        || fail "$query_name lacks a region, service, or exchange-rate result group"
      ;;
    5)
      jq -e --arg version "$git_sha" '
        [.[] | select(.service_version == $version)] as $current_rows |
        ($current_rows | length) >= 2 and
        ([$current_rows[].region] | unique | sort) == ["us-central1", "us-east4"] and
        all($current_rows[];
          .service == "app-b-engine" and
          .decision == "AUTH_REJECTED" and
          (.rejection_type | type == "string" and length > 0) and
          (.rejection_count | tonumber) > 0 and
          ((.region == "us-central1" and .cluster == "gke-risk-usc1") or
           (.region == "us-east4" and .cluster == "gke-risk-use4")))
      ' "$query_result" >/dev/null \
        || fail "$query_name did not prove current-release authentication denials in both cells"
      ;;
  esac
done

for output_file in \
  "$table_list_file" "$table_metadata" "$scope_result" \
  "$work_dir"/0[1-5]_*.json; do
  cp -- "$output_file" "$results_dir/$(basename "$output_file")"
done
cp -- "$manifest" "$results_dir/bigquery-seed.json"

printf 'Verified current SHA %s in partitioned BigQuery rows: both regions, both services, exchange-rate results, controlled errors, authentication denials, latency, trace joins, and zero export errors.\n' \
  "$git_sha"

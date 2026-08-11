#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$repo_root/.tmp/local-integration"
fault_dir="$runtime_dir/faults"
fault_file="$fault_dir/faults.json"
compose_env="$runtime_dir/compose.env"
expected_response_file="$repo_root/testdata/expected-exchange-rates.json"
project_id="${PROJECT_ID:-schwab-assessment-gke}"
work_dir=""
fault_active=0

fail() {
  printf 'local-verify: %s\n' "$*" >&2
  exit 1
}

write_fault() {
  local error_rate="$1"
  local fault_tmp="$fault_dir/faults.json.tmp"
  printf '%s\n' \
    '{' \
    '  "injected_latency_ms": 0,' \
    "  \"injected_error_rate\": $error_rate" \
    '}' >"$fault_tmp"
  mv -f "$fault_tmp" "$fault_file"
}

cleanup() {
  local exit_code=$?
  if ((fault_active)); then
    write_fault 0.0 || true
  fi
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

for required_command in curl docker git jq; do
  command -v "$required_command" >/dev/null 2>&1 \
    || fail "$required_command is required"
done
docker info >/dev/null 2>&1 || fail "Docker Desktop is not running"
[[ -f "$compose_env" ]] || fail "run scripts/local-up.sh first"
[[ -f "$fault_file" ]] || fail "generated fault configuration is missing"
[[ -f "$expected_response_file" ]] || fail "expected exchange-rate fixture is missing"
expected_service_version="$(awk -F= '$1 == "SERVICE_VERSION" {print $2}' "$compose_env" | tr -d '\r' | tail -n 1)"
[[ "$expected_service_version" =~ ^([0-9a-f]{40}|local-[0-9a-f]{12}-dirty)$ ]] \
  || fail "the local stack does not record an honest source version"
current_head="$(git -C "$repo_root" rev-parse HEAD)"
[[ "$current_head" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve the current Git HEAD"
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then
  current_source_version="local-${current_head:0:12}-dirty"
else
  current_source_version="$current_head"
fi
[[ "$expected_service_version" == "$current_source_version" ]] \
  || fail "the local stack source version is stale; rerun scripts/local-up.sh"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/schwab-assessment-local.XXXXXX")"
cd "$repo_root"

compose() {
  docker compose --env-file "$compose_env" "$@"
}

app_a_id="$(compose ps --quiet app-a-gateway | tr -d '\r')"
app_b_id="$(compose ps --quiet app-b-engine | tr -d '\r')"
[[ -n "$app_a_id" && -n "$app_b_id" ]] || fail "both Compose services must be running"

for container_id in "$app_a_id" "$app_b_id"; do
  docker inspect "$container_id" | jq -e \
    --arg version "SERVICE_VERSION=$expected_service_version" \
    --arg region "SERVICE_REGION=us-central1" \
    --arg cluster "SERVICE_CLUSTER=local-compose" '
    .[0].State.Running == true and
    .[0].State.Health.Status == "healthy" and
    .[0].Config.User == "10001:10001" and
    (.[0].Config.Env | index($version)) != null and
    (.[0].Config.Env | index($region)) != null and
    (.[0].Config.Env | index($cluster)) != null and
    ([.[0].Config.Env[] | select(startswith("RISK_REGION=") or startswith("RISK_CLUSTER="))] | length) == 0 and
    .[0].HostConfig.ReadonlyRootfs == true and
    (.[0].HostConfig.CapDrop | index("ALL")) != null and
    (.[0].HostConfig.SecurityOpt | index("no-new-privileges:true")) != null
  ' >/dev/null || fail "container runtime hardening or health check failed"
done

docker inspect "$app_b_id" | jq -e '.[0].NetworkSettings.Ports["8080/tcp"] == null' \
  >/dev/null || fail "App B unexpectedly has a published host port"

auth_audience="https://app-b-engine.schwab-assessment.internal"
security_csp="default-src 'none'; script-src 'sha256-9cpFYLGEb43nFRxcezVuHD2huh05Y6/t011BpLqwRvE='; style-src 'sha256-B3k4aPo0RwYE847u9eMw0awwLce/65GM8iBUMLVg54Q='; img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
docker inspect "$app_a_id" | jq -e \
  --arg mode "APP_B_AUTH_MODE=disabled" \
  --arg audience "APP_B_TOKEN_AUDIENCE=$auth_audience" \
  --arg project "GOOGLE_CLOUD_PROJECT=$project_id" \
  --arg profile "SPRING_PROFILES_ACTIVE=local-compose" '
    (.[0].Config.Env | index($mode)) != null and
    (.[0].Config.Env | index($audience)) != null and
    (.[0].Config.Env | index($project)) != null and
    (.[0].Config.Env | index($profile)) != null
  ' >/dev/null || fail "local App A must use the explicit no-metadata auth mode"
docker inspect "$app_b_id" | jq -e \
  --arg environment "ASPNETCORE_ENVIRONMENT=LocalCompose" \
  --arg mode "APP_B_AUTH_MODE=disabled" \
  --arg audience "APP_B_TOKEN_AUDIENCE=$auth_audience" \
  --arg project "GOOGLE_CLOUD_PROJECT=$project_id" \
  --arg caller "APP_A_IDENTITY_EMAIL=currency-app-a-caller@$project_id.iam.gserviceaccount.com" '
    (.[0].Config.Env | index($environment)) != null and
    (.[0].Config.Env | index($mode)) != null and
    (.[0].Config.Env | index($audience)) != null and
    (.[0].Config.Env | index($project)) != null and
    (.[0].Config.Env | index($caller)) != null
  ' >/dev/null || fail "local App B auth configuration is incomplete"

binding="$(compose port app-a-gateway 8080 | tr -d '\r' | tail -n 1)"
[[ "$binding" == 127.0.0.1:* ]] || fail "App A is not bound only to loopback"
host_port="${binding##*:}"
[[ "$host_port" =~ ^[0-9]+$ ]] || fail "could not resolve App A's random host port"
base_url="http://127.0.0.1:$host_port"

header_value() {
  local headers_file="$1"
  local header_name="$2"
  tr -d '\r' <"$headers_file" \
    | awk -F ': ' -v expected="${header_name,,}" 'tolower($1) == expected {print $2}' \
    | tail -n 1
}

header_count() {
  local headers_file="$1"
  local header_name="$2"
  tr -d '\r' <"$headers_file" \
    | awk -F ': ' -v expected="${header_name,,}" 'tolower($1) == expected {count++} END {print count + 0}'
}

assert_exchange_rates() {
  local response_file="$1"
  local expected_region="$2"
  local expected_cluster="$3"
  local expected_version="$4"
  jq -e \
    --slurpfile expected "$expected_response_file" \
    --arg region "$expected_region" \
    --arg cluster "$expected_cluster" \
    --arg version "$expected_version" '
      (keys == ["baseCurrency", "disclaimer", "providedBy", "rateSnapshots"]) and
      (.rateSnapshots | length == 10) and
      all(.rateSnapshots[]; keys == ["EUR", "GBP", "JPY"]) and
      (.providedBy | keys == ["cluster", "region", "service", "version"]) and
      .baseCurrency == $expected[0].baseCurrency and
      .rateSnapshots == $expected[0].rateSnapshots and
      .disclaimer == $expected[0].disclaimer and
      .providedBy.service == $expected[0].providedBy.service and
      .providedBy.region == $region and
      .providedBy.cluster == $cluster and
      .providedBy.version == $version
    ' "$response_file" >/dev/null \
    || fail "exchange-rate response does not match the frozen contract"
}

assert_app_b_health() {
  local path="$1"
  MSYS_NO_PATHCONV=1 docker exec "$app_b_id" bash -ec '
    path="$1"
    exec 3<>/dev/tcp/127.0.0.1/8080
    printf "GET %s HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" "$path" >&3
    IFS=" " read -r _ status _ <&3
    [[ "$status" == "200" ]]
  ' bash "$path" >/dev/null || fail "App B $path did not return HTTP 200"
}

assert_app_a_health() {
  local path="$1"
  local output="$work_dir/app-a-health.json"
  local status
  status="$(curl --silent --show-error --max-time 3 \
    --output "$output" --write-out '%{http_code}' "$base_url$path")"
  [[ "$status" == "200" ]] || fail "App A $path returned HTTP $status"
  jq -e '.status == "UP"' "$output" >/dev/null \
    || fail "App A $path returned an unexpected body"
}

wait_for_cell() {
  local expected_state="$1"
  local expected_status="$2"
  local timeout_seconds="$3"
  local output="$work_dir/cell.json"
  local deadline=$((SECONDS + timeout_seconds))
  local status

  while ((SECONDS < deadline)); do
    status="$(curl --silent --show-error --max-time 3 \
      --output "$output" --write-out '%{http_code}' "$base_url/health/cell" || true)"
    if [[ "$status" == "$expected_status" ]] \
      && jq -e --arg state "$expected_state" '.status == $state' "$output" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  fail "cell health did not reach $expected_state/HTTP $expected_status within ${timeout_seconds}s"
}

random_hex() {
  local bytes="$1"
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

request_raw="$(random_hex 16)"
correlation_id="${request_raw:0:8}-${request_raw:8:4}-${request_raw:12:4}-${request_raw:16:4}-${request_raw:20:12}"
trace_id="$(random_hex 16)"
span_id="$(random_hex 8)"
traceparent="00-$trace_id-$span_id-01"

assert_app_a_health /health/live
assert_app_a_health /health/ready
assert_app_b_health /health/live
assert_app_b_health /health/ready
wait_for_cell HEALTHY 200 45

ui_headers="$work_dir/ui-headers.txt"
ui_status="$(curl --silent --show-error --max-time 5 \
  --dump-header "$ui_headers" \
  --output "$work_dir/index.html" \
  --write-out '%{http_code}' "$base_url/")"
[[ "$ui_status" == "200" ]] || fail "App A UI returned HTTP $ui_status"
[[ "$(header_value "$ui_headers" content-type)" == text/html* ]] \
  || fail "App A UI did not return text/html"
[[ "$(header_value "$ui_headers" cache-control)" == "no-store" ]] \
  || fail "App A UI did not return Cache-Control: no-store"
[[ "$(header_value "$ui_headers" x-content-type-options)" == "nosniff" ]] \
  && [[ "$(header_value "$ui_headers" x-frame-options)" == "DENY" ]] \
  && [[ "$(header_value "$ui_headers" content-security-policy)" == "$security_csp" ]] \
  || fail "App A UI security headers do not match the hardened contract"
[[ "$(header_count "$ui_headers" strict-transport-security)" == "0" ]] \
  || fail "loopback HTTP must not emit HSTS"
for marker in \
  'id="exchange-rate-app"' \
  'data-api-endpoint="/api/exchange-rates"' \
  'data-snapshot-count="10"' \
  'id="sample-position"' \
  'id="serving-region"' \
  'id="trace-id"' \
  'payload.rateSnapshots.length !== 10' \
  'let sampleIndex = -1' \
  'if (advanceSample || sampleIndex < 0)' \
  'sampleIndex = (sampleIndex + 1) % payload.rateSnapshots.length' \
  'cache: "no-store"' \
  'response.headers.get("x-trace-id")' \
  'Region: ${source.region}' \
  'Trace ID: ${traceId}' \
  'loadRates(true)' \
  'loadRates(false)' \
  'Synthetic demonstration rates - not for financial use.' \
  'data-currency="EUR"' \
  'data-currency="GBP"' \
  'data-currency="JPY"'; do
  grep -F -q -- "$marker" "$work_dir/index.html" \
    || fail "App A UI is missing marker: $marker"
done
for hidden_marker in '${source.service}' '${source.cluster}' '${source.version}'; do
  ! grep -F -q -- "$hidden_marker" "$work_dir/index.html" \
    || fail "App A UI exposes internal metadata: $hidden_marker"
done

for attempt in 1 2; do
  response="$work_dir/response-$attempt.json"
  headers="$work_dir/headers-$attempt.txt"
  status="$(curl --silent --show-error --max-time 5 \
    --dump-header "$headers" \
    --output "$response" \
    --write-out '%{http_code}' \
    --request GET "$base_url/api/exchange-rates" \
    --header "x-correlation-id: $correlation_id" \
    --header "traceparent: $traceparent")"
  [[ "$status" == "200" ]] || fail "exchange-rate request $attempt returned HTTP $status"
  assert_exchange_rates "$response" us-central1 local-compose "$expected_service_version"
  [[ "$(header_value "$headers" content-type)" == application/json* ]] \
    || fail "exchange-rate response $attempt did not return application/json"
  [[ "$(header_value "$headers" cache-control)" == "no-store" ]] \
    || fail "exchange-rate response $attempt did not return Cache-Control: no-store"
  [[ "$(header_count "$headers" cache-control)" == "1" ]] \
    || fail "exchange-rate response $attempt returned duplicate Cache-Control headers"
  [[ "$(header_value "$headers" x-content-type-options)" == "nosniff" ]] \
    && [[ "$(header_value "$headers" x-frame-options)" == "DENY" ]] \
    && [[ "$(header_value "$headers" content-security-policy)" == "$security_csp" ]] \
    || fail "exchange-rate response $attempt is missing hardened security headers"

  returned_correlation="$(tr -d '\r' <"$headers" | awk -F ': ' 'tolower($1)=="x-correlation-id" {print $2}' | tail -n 1)"
  returned_trace_id="$(header_value "$headers" x-trace-id)"
  returned_traceparent="$(tr -d '\r' <"$headers" | awk -F ': ' 'tolower($1)=="traceparent" {print $2}' | tail -n 1)"
  [[ "$returned_correlation" == "$correlation_id" ]] \
    || fail "App A did not preserve the response correlation ID"
  [[ "$returned_traceparent" == "$traceparent" ]] \
    || fail "App A did not preserve the response trace context"
  [[ "$returned_trace_id" == "$trace_id" ]] \
    || fail "App A response trace ID does not match the structured-log trace ID"
done

jq -S -c . "$work_dir/response-1.json" >"$work_dir/response-1.canonical"
jq -S -c . "$work_dir/response-2.json" >"$work_dir/response-2.canonical"
cmp -s "$work_dir/response-1.canonical" "$work_dir/response-2.canonical" \
  || fail "repeated exchange-rate requests produced different responses"

generated_headers="$work_dir/generated-headers.txt"
generated_status="$(curl --silent --show-error --max-time 5 \
  --dump-header "$generated_headers" \
  --output "$work_dir/generated-response.json" \
  --write-out '%{http_code}' \
  --request GET "$base_url/api/exchange-rates")"
[[ "$generated_status" == "200" ]] \
  || fail "header-generation request returned HTTP $generated_status"
assert_exchange_rates "$work_dir/generated-response.json" \
  us-central1 local-compose "$expected_service_version"
generated_correlation="$(header_value "$generated_headers" x-correlation-id)"
generated_trace_id="$(header_value "$generated_headers" x-trace-id)"
generated_traceparent="$(header_value "$generated_headers" traceparent)"
[[ "$generated_correlation" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] \
  || fail "App A did not generate a valid correlation ID"
[[ "$generated_traceparent" =~ ^00-[0-9a-f]{32}-[0-9a-f]{16}-0[1-9a-f]$ ]] \
  || fail "App A did not generate valid trace context"
[[ "$generated_trace_id" =~ ^[0-9a-f]{32}$ ]] \
  && [[ "$generated_trace_id" == "${generated_traceparent:3:32}" ]] \
  || fail "App A did not expose the generated structured-log trace ID"

wait_for_request_logs() {
  local deadline=$((SECONDS + 15))
  local app_a_log="$work_dir/app-a.log"
  local app_b_log="$work_dir/app-b.log"

  while ((SECONDS < deadline)); do
    docker logs "$app_a_id" >"$app_a_log" 2>&1
    docker logs "$app_b_id" >"$app_b_log" 2>&1
    if jq -e --arg correlation "$correlation_id" --arg trace "$trace_id" '
         select(.service? == "app-a-gateway" and
                .log_type == "request" and
                .route == "/api/exchange-rates" and
                .method == "GET" and
                .status_code == 200 and
                .decision == "RATES_RETURNED" and
                .correlation_id == $correlation and
                .trace_id == $trace)
       ' "$app_a_log" >/dev/null 2>&1 \
      && jq -e --arg correlation "$correlation_id" --arg trace "$trace_id" '
         select(.service? == "app-b-engine" and
                .log_type == "request" and
                .route == "/internal/exchange-rates" and
                .method == "GET" and
                .status_code == 200 and
                .decision == "RATES_RETURNED" and
                .correlation_id == $correlation and
                .trace_id == $trace)
       ' "$app_b_log" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  fail "matching App A and App B request logs were not emitted"
}

wait_for_request_logs

fault_raw="$(random_hex 16)"
fault_correlation="${fault_raw:0:8}-${fault_raw:8:4}-${fault_raw:12:4}-${fault_raw:16:4}-${fault_raw:20:12}"
fault_trace_id="$(random_hex 16)"
fault_span_id="$(random_hex 8)"
fault_traceparent="00-$fault_trace_id-$fault_span_id-01"

write_fault 1.0
fault_active=1
wait_for_cell UNHEALTHY 503 45
assert_app_a_health /health/live
assert_app_a_health /health/ready
assert_app_b_health /health/live
assert_app_b_health /health/ready

fault_headers="$work_dir/fault-headers.txt"
fault_status="$(curl --silent --show-error --max-time 5 \
  --dump-header "$fault_headers" \
  --output "$work_dir/fault-response.json" \
  --write-out '%{http_code}' \
  --request GET "$base_url/api/exchange-rates" \
  --header "x-correlation-id: $fault_correlation" \
  --header "traceparent: $fault_traceparent")"
[[ "$fault_status" == "503" ]] || fail "faulted dependency returned HTTP $fault_status instead of 503"
[[ "$(header_value "$fault_headers" cache-control)" == "no-store" ]] \
  || fail "faulted dependency did not return Cache-Control: no-store"
[[ "$(header_count "$fault_headers" cache-control)" == "1" ]] \
  || fail "faulted dependency returned duplicate Cache-Control headers"
[[ "$(header_value "$fault_headers" x-correlation-id)" == "$fault_correlation" ]] \
  || fail "faulted dependency did not preserve the correlation ID"
[[ "$(header_value "$fault_headers" traceparent)" == "$fault_traceparent" ]] \
  || fail "faulted dependency did not preserve the trace context"
[[ "$(header_value "$fault_headers" x-trace-id)" == "$fault_trace_id" ]] \
  || fail "faulted dependency did not expose the structured-log trace ID"
jq -e '
  .error == "DEPENDENCY_UNAVAILABLE" and
  .message == "Exchange rates are temporarily unavailable"
' "$work_dir/fault-response.json" >/dev/null \
  || fail "App A leaked or changed the bounded dependency error"

write_fault 0.0
fault_active=0
wait_for_cell HEALTHY 200 75

recovery_status="$(curl --silent --show-error --max-time 5 \
  --output "$work_dir/recovery-response.json" \
  --write-out '%{http_code}' \
  --request GET "$base_url/api/exchange-rates" \
  --header "x-correlation-id: $correlation_id" \
  --header "traceparent: $traceparent")"
[[ "$recovery_status" == "200" ]] || fail "request path did not recover after the fault"
assert_exchange_rates "$work_dir/recovery-response.json" us-central1 local-compose "$expected_service_version"

docker logs "$app_a_id" >"$work_dir/app-a.log" 2>&1
docker logs "$app_b_id" >"$work_dir/app-b.log" 2>&1
jq -e . "$work_dir/app-a.log" >/dev/null || fail "an App A log line is not JSON"
jq -e . "$work_dir/app-b.log" >/dev/null || fail "an App B log line is not JSON"

required_fields='["severity","message","log_type","service","service_version","region","cluster","correlation_id","trace_id","route","method","status_code","latency_ms","downstream_latency_ms","decision","error_type","stack_trace","is_test","logging.googleapis.com/trace"]'

validate_service_logs() {
  local service="$1"
  local log_file="$2"
  jq -s -e \
    --arg service "$service" \
    --arg version "$expected_service_version" \
    --argjson required "$required_fields" '
    [.[] | select(.service? == $service)] as $events |
    ($events | length) > 0 and
    any($events[]; .log_type == "schema_seed") and
    all($events[];
      . as $event |
      (($event | keys) == ($required | sort)) and
      ((.severity | type) == "string") and
      ((.message | type) == "string") and
      (["schema_seed", "request", "dependency_probe", "lifecycle"] | index($event.log_type)) != null and
      .service_version == $version and
      ((.region | type) == "string") and
      ((.cluster | type) == "string") and
      ((.correlation_id | type) == "string") and
      ((.trace_id | type) == "string") and
      ((.route | type) == "string") and
      ((.method | type) == "string") and
      ((.status_code | type) == "number") and .status_code >= 0 and
      ((.latency_ms | type) == "number") and .latency_ms >= 0 and
      ((.downstream_latency_ms | type) == "number") and .downstream_latency_ms >= 0 and
      ((.decision | type) == "string") and
      ((.error_type | type) == "string") and
      ((.stack_trace | type) == "string") and
      ((.is_test | type) == "boolean") and
      ((.["logging.googleapis.com/trace"] | type) == "string") and
      (.severity != "ERROR" or (.stack_trace | length) > 0)
    )
  ' "$log_file" >/dev/null || fail "$service logs violate the frozen JSON schema"
}

validate_service_logs app-a-gateway "$work_dir/app-a.log"
validate_service_logs app-b-engine "$work_dir/app-b.log"

expected_google_trace="projects/$project_id/traces/$trace_id"
for service_log in "$work_dir/app-a.log" "$work_dir/app-b.log"; do
  jq -e \
    --arg correlation "$correlation_id" \
    --arg trace "$trace_id" \
    --arg google_trace "$expected_google_trace" '
      select(.log_type? == "request" and
             .status_code == 200 and
             .correlation_id == $correlation and
             .trace_id == $trace and
             .["logging.googleapis.com/trace"] == $google_trace)
    ' "$service_log" >/dev/null \
    || fail "request correlation/trace fields do not match across services"
done

jq -e \
  --arg correlation "$fault_correlation" \
  --arg trace "$fault_trace_id" '
    select((.log_type? == "request") and
           (.status_code >= 500) and
           (.correlation_id == $correlation) and
           (.trace_id == $trace))
  ' "$work_dir/app-a.log" >/dev/null \
  || fail "the bounded public fault was not traceable in App A logs"

# Once the cell is unhealthy, App A may correctly reject the explicit request
# from its open circuit without calling App B. Prove cross-service fault
# traceability with any matching request or dependency-probe pair from this
# fresh-container run instead of requiring that circuit-short-circuited call in
# App B.
jq -n -e \
  --slurpfile app_a "$work_dir/app-a.log" \
  --slurpfile app_b "$work_dir/app-b.log" '
    [
      $app_a[]
      | select(
          (.log_type == "request" or .log_type == "dependency_probe")
          and .status_code >= 500)
      | [.correlation_id, .trace_id]
    ] as $app_a_pairs
    | [
        $app_b[]
        | select(
            (.log_type == "request" or .log_type == "dependency_probe")
            and .status_code >= 500)
        | [.correlation_id, .trace_id]
      ] as $app_b_pairs
    | any($app_a_pairs[]; . as $pair | any($app_b_pairs[]; . == $pair))
  ' >/dev/null \
  || fail "no faulted App A/App B log pair shared correlation and trace IDs"

printf 'Local integration verification passed.\n'
printf 'Endpoint: %s\n' "$base_url"
printf 'Service version: %s\n' "$expected_service_version"
printf 'Deterministic catalog: 10 snapshots; sample 1 USD EUR=0.92 GBP=0.78 JPY=149.50\n'
printf 'Log decision: RATES_RETURNED\n'
printf 'Correlation ID: %s\n' "$correlation_id"
printf 'Trace ID: %s\n' "$trace_id"
printf 'Cell path: HEALTHY -> UNHEALTHY -> HEALTHY\n'

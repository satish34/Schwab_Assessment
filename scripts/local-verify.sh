#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$repo_root/.tmp/local-integration"
fault_dir="$runtime_dir/faults"
fault_file="$fault_dir/faults.json"
compose_env="$runtime_dir/compose.env"
request_file="$repo_root/testdata/request.json"
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
[[ -f "$request_file" ]] || fail "canonical request fixture is missing"
expected_service_version="$(awk -F= '$1 == "SERVICE_VERSION" {print $2}' "$compose_env" | tr -d '\r' | tail -n 1)"
[[ "$expected_service_version" =~ ^[0-9a-f]{40}$ ]] \
  || fail "the local stack does not record a full Git SHA"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/schwab-assessment-local.XXXXXX")"
cd "$repo_root"

compose() {
  docker compose --env-file "$compose_env" "$@"
}

app_a_id="$(compose ps --quiet app-a-gateway | tr -d '\r')"
app_b_id="$(compose ps --quiet app-b-engine | tr -d '\r')"
[[ -n "$app_a_id" && -n "$app_b_id" ]] || fail "both Compose services must be running"

for container_id in "$app_a_id" "$app_b_id"; do
  docker inspect "$container_id" | jq -e --arg version "SERVICE_VERSION=$expected_service_version" '
    .[0].State.Running == true and
    .[0].State.Health.Status == "healthy" and
    .[0].Config.User == "10001:10001" and
    (.[0].Config.Env | index($version)) != null and
    .[0].HostConfig.ReadonlyRootfs == true and
    (.[0].HostConfig.CapDrop | index("ALL")) != null and
    (.[0].HostConfig.SecurityOpt | index("no-new-privileges:true")) != null
  ' >/dev/null || fail "container runtime hardening or health check failed"
done

docker inspect "$app_b_id" | jq -e '.[0].NetworkSettings.Ports["8080/tcp"] == null' \
  >/dev/null || fail "App B unexpectedly has a published host port"

binding="$(compose port app-a-gateway 8080 | tr -d '\r' | tail -n 1)"
[[ "$binding" == 127.0.0.1:* ]] || fail "App A is not bound only to loopback"
host_port="${binding##*:}"
[[ "$host_port" =~ ^[0-9]+$ ]] || fail "could not resolve App A's random host port"
base_url="http://127.0.0.1:$host_port"

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

for attempt in 1 2; do
  response="$work_dir/response-$attempt.json"
  headers="$work_dir/headers-$attempt.txt"
  status="$(curl --silent --show-error --max-time 5 \
    --dump-header "$headers" \
    --output "$response" \
    --write-out '%{http_code}' \
    --request POST "$base_url/v1/risk" \
    --header 'Content-Type: application/json' \
    --header "x-correlation-id: $correlation_id" \
    --header "traceparent: $traceparent" \
    --data-binary "@$request_file")"
  [[ "$status" == "200" ]] || fail "deterministic request $attempt returned HTTP $status"
  jq -e --arg version "$expected_service_version" '
    .requestId == "550e8400-e29b-41d4-a716-446655440000" and
    .score == 48 and
    .decision == "REVIEW" and
    .rulesFired == ["CARD_NOT_PRESENT", "AMOUNT_OVER_1000"] and
    .evaluatedBy.service == "app-b-engine" and
    .evaluatedBy.region == "us-central1" and
    .evaluatedBy.cluster == "local-compose" and
    .evaluatedBy.version == $version
  ' "$response" >/dev/null || fail "response $attempt does not match the frozen contract"

  returned_correlation="$(tr -d '\r' <"$headers" | awk -F ': ' 'tolower($1)=="x-correlation-id" {print $2}' | tail -n 1)"
  returned_traceparent="$(tr -d '\r' <"$headers" | awk -F ': ' 'tolower($1)=="traceparent" {print $2}' | tail -n 1)"
  [[ "$returned_correlation" == "$correlation_id" ]] \
    || fail "App A did not preserve the response correlation ID"
  [[ "$returned_traceparent" == "$traceparent" ]] \
    || fail "App A did not preserve the response trace context"
done

jq -S -c . "$work_dir/response-1.json" >"$work_dir/response-1.canonical"
jq -S -c . "$work_dir/response-2.json" >"$work_dir/response-2.canonical"
cmp -s "$work_dir/response-1.canonical" "$work_dir/response-2.canonical" \
  || fail "the same request produced different decisions"

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
                .status_code == 200 and
                .correlation_id == $correlation and
                .trace_id == $trace)
       ' "$app_a_log" >/dev/null 2>&1 \
      && jq -e --arg correlation "$correlation_id" --arg trace "$trace_id" '
         select(.service? == "app-b-engine" and
                .log_type == "request" and
                .status_code == 200 and
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

fault_status="$(curl --silent --show-error --max-time 5 \
  --output "$work_dir/fault-response.json" \
  --write-out '%{http_code}' \
  --request POST "$base_url/v1/risk" \
  --header 'Content-Type: application/json' \
  --header "x-correlation-id: $fault_correlation" \
  --header "traceparent: $fault_traceparent" \
  --data-binary "@$request_file")"
[[ "$fault_status" == "503" ]] || fail "faulted dependency returned HTTP $fault_status instead of 503"
jq -e '
  .error == "DEPENDENCY_UNAVAILABLE" and
  .message == "Risk evaluation is temporarily unavailable"
' "$work_dir/fault-response.json" >/dev/null \
  || fail "App A leaked or changed the bounded dependency error"

write_fault 0.0
fault_active=0
wait_for_cell HEALTHY 200 75

recovery_status="$(curl --silent --show-error --max-time 5 \
  --output "$work_dir/recovery-response.json" \
  --write-out '%{http_code}' \
  --request POST "$base_url/v1/risk" \
  --header 'Content-Type: application/json' \
  --header "x-correlation-id: $correlation_id" \
  --header "traceparent: $traceparent" \
  --data-binary "@$request_file")"
[[ "$recovery_status" == "200" ]] || fail "request path did not recover after the fault"

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
      (($required - ($event | keys)) | length) == 0 and
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

for service_log in "$work_dir/app-a.log" "$work_dir/app-b.log"; do
  jq -e \
    --arg correlation "$fault_correlation" \
    --arg trace "$fault_trace_id" '
      select((.log_type? == "request") and
             (.status_code >= 500) and
             (.correlation_id == $correlation) and
             (.trace_id == $trace))
    ' "$service_log" >/dev/null \
    || fail "the bounded fault was not traceable in both service logs"
done

printf 'Local integration verification passed.\n'
printf 'Endpoint: %s\n' "$base_url"
printf 'Service version: %s\n' "$expected_service_version"
printf 'Deterministic result: score=48 decision=REVIEW\n'
printf 'Correlation ID: %s\n' "$correlation_id"
printf 'Trace ID: %s\n' "$trace_id"
printf 'Cell path: HEALTHY -> UNHEALTHY -> HEALTHY\n'

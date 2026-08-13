#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
mode="${1:-}"

fail() {
  printf 'verify-cloud-observability: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

verify_static() {
  local rendered pattern
  for command_name in git grep jq kubectl mktemp; do
    require_command "$command_name"
  done
  mkdir -p "$repo_root/.tmp"
  rendered="$(mktemp "$repo_root/.tmp/cloud-observability.XXXXXX")"
  trap 'rm -f -- "$rendered"' RETURN
  git check-ignore --quiet -- "$rendered" || fail "static render path must be ignored"
  kubectl kustomize k8s/overlays/us-central1 >"$rendered"

  for api in cloudprofiler.googleapis.com cloudtrace.googleapis.com telemetry.googleapis.com; do
    grep -Fq "$api" infra/00-bootstrap/main.tf || fail "$api is not managed by bootstrap Terraform"
  done
  for role in roles/cloudprofiler.agent roles/serviceusage.serviceUsageConsumer roles/telemetry.tracesWriter; do
    grep -Fq "$role" infra/10-global/iam.tf || fail "$role is not managed by global Terraform"
  done
  grep -Fq 'account_id   = "currency-app-b-telemetry"' infra/10-global/iam.tf \
    || fail "dedicated App B telemetry GSA is missing"
  grep -Fq 'currency-app-a/app-a-gateway' infra/10-global/iam.tf \
    || fail "App A exact Workload Identity mapping is missing"
  grep -Fq 'currency-app-b/app-b-engine' infra/10-global/iam.tf \
    || fail "App B exact Workload Identity mapping is missing"
  grep -Fq 'currency-observability/currency-grafana' infra/10-global/iam.tf \
    || fail "Grafana exact Workload Identity mapping is missing"

  grep -Fq 'name: OTEL_TRACING_ENABLED' "$rendered" \
    && grep -Fq 'name: CLOUD_PROFILER_ENABLED' "$rendered" \
    && grep -Fq 'name: OTEL_TRACES_SAMPLER_ARG' "$rendered" \
    || fail "App A tracing, profiler, or sampling env is missing"
  grep -Fq 'name: OTEL_TRACES_EXPORTER' "$rendered" \
    && grep -Fq 'value: https://telemetry.googleapis.com/v1/traces' "$rendered" \
    && grep -Fq 'name: OTEL_EXPORTER_OTLP_PROTOCOL' "$rendered" \
    || fail "App B direct Telemetry API export env is missing"
  grep -Fq 'currency-app-b-telemetry@PROJECT_ID.iam.gserviceaccount.com' "$rendered" \
    || fail "App B KSA telemetry annotation is missing"

  pattern='currency-otel-collec''tor|opentelemetry-collec''tor|otel-collec''tor|4317'
  if git grep -n -E "$pattern" -- infra k8s observability scripts apps \
    ':(exclude)scripts/verify-cloud-observability.sh'; then
    fail "collector-based telemetry artifact remains; direct export must have zero collector Pods"
  else
    grep_status=$?
    [[ "$grep_status" == 1 ]] || fail "collector artifact scan failed"
  fi
  bash scripts/gke-grafana-evidence.sh static
  printf '%s\n' \
    'Cloud observability source contract: PASS (direct keyless traces, App A Profiler, no collector, private ephemeral Grafana).'
  trap - RETURN
  rm -f -- "$rendered"
}

if [[ "$mode" == --static ]]; then
  verify_static
  exit 0
fi

[[ $# -eq 2 ]] || {
  printf 'Usage: %s --static | FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  exit 2
}
app_a_sha="$1"
app_b_sha="$2"
[[ "$app_a_sha" =~ ^[0-9a-f]{40}$ && "$app_b_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "both versions must be full lowercase 40-character Git SHAs"
verify_static

for command_name in curl date gcloud git jq od sed sleep; do
  require_command "$command_name"
done
: "${PROJECT_ID:=schwab-assessment-gke}"
: "${GCLOUD_CONFIGURATION:=schwab-assessment}"
: "${DOMAIN_NAME:=satish.store}"
expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
[[ "$PROJECT_ID" == "$expected_project" ]] || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"
[[ "$DOMAIN_NAME" =~ ^[a-z0-9.-]+$ && "$DOMAIN_NAME" != *..* ]] \
  || fail "DOMAIN_NAME is invalid"
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_ACCESS_TOKEN GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_KEYFILE_JSON \
  GOOGLE_CREDENTIALS GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] || fail "$override_name must be unset"
done
active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
for auth_property in \
  auth/access_token_file auth/credential_file_override \
  auth/impersonate_service_account; do
  auth_value="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value "$auth_property" 2>/dev/null)"
  [[ -z "$auth_value" || "$auth_value" == "(unset)" ]] \
    || fail "$auth_property must be unset in the named gcloud configuration"
done
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected project $PROJECT_ID, found ${configured_project:-<none>}"
for sha in "$app_a_sha" "$app_b_sha"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || fail "$sha is not a local commit"
done

required_services="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
  --account="$expected_account" --project="$PROJECT_ID" services list \
  --enabled --filter='config.name:(cloudprofiler.googleapis.com OR cloudtrace.googleapis.com OR telemetry.googleapis.com)' \
  --format='value(config.name)' | tr -d '\r' | sort)"
[[ "$required_services" == $'cloudprofiler.googleapis.com\ncloudtrace.googleapis.com\ntelemetry.googleapis.com' ]] \
  || fail "Cloud Profiler, Trace, and Telemetry APIs must all be enabled"

# Reuse the authoritative two-cell verifier for live image versions, direct
# exporter env, KSA annotations, readiness, auth denial, and App A -> App B.
PROJECT_ID="$PROJECT_ID" GCLOUD_CONFIGURATION="$GCLOUD_CONFIGURATION" \
  bash scripts/verify-workloads.sh "$app_a_sha" "$app_b_sha"

project_policy="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
  --account="$expected_account" --project="$PROJECT_ID" projects get-iam-policy "$PROJECT_ID" \
  --format=json)"
jq -e \
  --arg app_a "serviceAccount:currency-app-a-caller@$PROJECT_ID.iam.gserviceaccount.com" \
  --arg app_b "serviceAccount:currency-app-b-telemetry@$PROJECT_ID.iam.gserviceaccount.com" '
  def roles_for($member): [.bindings[] | select((.members // []) | index($member)) | .role] | sort;
  roles_for($app_a) == [
    "roles/cloudprofiler.agent",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/telemetry.tracesWriter"
  ] and roles_for($app_b) == [
    "roles/serviceusage.serviceUsageConsumer",
    "roles/telemetry.tracesWriter"
  ]
' <<<"$project_policy" >/dev/null || fail "runtime telemetry IAM is not exact"

access_token="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
  --account="$expected_account" auth print-access-token)"
[[ -n "$access_token" ]] || fail "could not obtain the operator access token"
cleanup() {
  unset access_token project_policy
}
trap cleanup EXIT INT TERM

gcp_get() {
  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    | MSYS_NO_PATHCONV=1 curl --config - --silent --show-error \
        --max-time 30 "$@"
}

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

headers="$(mktemp "$repo_root/.tmp/cloud-trace-headers.XXXXXX")"
body="$(mktemp "$repo_root/.tmp/cloud-trace-body.XXXXXX")"
git check-ignore --quiet -- "$headers" \
  || fail "trace response files must be ignored"
git check-ignore --quiet -- "$body" \
  || fail "trace response files must be ignored"
trap 'rm -f -- "$headers" "$body"; cleanup' EXIT INT TERM
sampled_trace_id=""
saw_server_rejection=0
# A public caller cannot force export with trace-flags=01. Let App A make the
# authoritative independent 10% decision and inspect its returned traceparent.
for _ in $(seq 1 60); do
  trace_id="$(random_hex 16)"
  upstream_span_id="$(random_hex 8)"
  correlation_raw="$(random_hex 16)"
  correlation_id="${correlation_raw:0:8}-${correlation_raw:8:4}-${correlation_raw:12:4}-${correlation_raw:16:4}-${correlation_raw:20:12}"
  status="$(curl --silent --show-error --max-time 15 \
    --dump-header "$headers" --output "$body" --write-out '%{http_code}' \
    --header 'Accept: application/json' \
    --header "x-correlation-id: $correlation_id" \
    --header "traceparent: 00-$trace_id-$upstream_span_id-01" \
    "https://$DOMAIN_NAME/api/exchange-rates")"
  [[ "$status" == 200 ]] \
    || fail "trace sampling request returned HTTP ${status:-<none>}"
  returned_trace_id="$(tr -d '\r' <"$headers" \
    | awk -F ': *' 'tolower($1)=="x-trace-id" {print tolower($2)}' | tail -n 1)"
  [[ "$returned_trace_id" == "$trace_id" ]] \
    || fail "public response did not preserve the reviewer-visible trace ID"
  returned_traceparent="$(tr -d '\r' <"$headers" \
    | awk -F ': *' 'tolower($1)=="traceparent" {print tolower($2)}' | tail -n 1)"
  [[ "$returned_traceparent" =~ ^00-$trace_id-[0-9a-f]{16}-0[01]$ ]] \
    || fail "public response did not return a valid server-authoritative traceparent"
  jq -e --arg app_b_sha "$app_b_sha" \
    '.providedBy.service == "app-b-engine" and .providedBy.version == $app_b_sha' \
    "$body" >/dev/null || fail "public trace request did not traverse current App B"
  if [[ "$returned_traceparent" == *-00 ]]; then
    saw_server_rejection=1
  elif [[ -z "$sampled_trace_id" ]]; then
    sampled_trace_id="$trace_id"
  fi
  if [[ -n "$sampled_trace_id" && "$saw_server_rejection" == "1" ]]; then
    break
  fi
done
[[ -n "$sampled_trace_id" ]] \
  || fail "App A made no independent sampled decision within 60 bounded requests"
[[ "$saw_server_rejection" == "1" ]] \
  || fail "App A did not prove that a caller-supplied sampled flag can be rejected"

trace_response=""
trace_verified=0
verified_trace_id=""
for _ in $(seq 1 30); do
  trace_response="$(gcp_get \
    "https://cloudtrace.googleapis.com/v1/projects/$PROJECT_ID/traces/$sampled_trace_id")"
    if jq -e --arg app_a_sha "$app_a_sha" --arg app_b_sha "$app_b_sha" '
      (.spans // []) as $spans |
      ([ $spans[] | select(.name == "GET /api/exchange-rates" and .kind == "RPC_SERVER") ] | length == 1) and
      ([ $spans[] | select(.name == "GET app-b-engine/internal/exchange-rates" and .kind == "RPC_CLIENT") ] | length == 1) and
      ([ $spans[] | select(.name == "GET /internal/exchange-rates" and .kind == "RPC_SERVER") ] | length == 1) and
      ([ $spans[] | select(.name == "GET /api/exchange-rates" and .kind == "RPC_SERVER") ][0]) as $a_server |
      ([ $spans[] | select(.name == "GET app-b-engine/internal/exchange-rates" and .kind == "RPC_CLIENT") ][0]) as $a_client |
      ([ $spans[] | select(.name == "GET /internal/exchange-rates" and .kind == "RPC_SERVER") ][0]) as $b_server |
      ($a_client.parentSpanId == $a_server.spanId) and
      ($b_server.parentSpanId == $a_client.spanId) and
      ([ $a_server.spanId, $a_client.spanId, $b_server.spanId ] | unique | length == 3) and
      all([$a_server, $a_client][];
        .labels["assessment.service.name"] == "app-a-gateway" and
        .labels["assessment.service.version"] == $app_a_sha) and
      ($b_server.labels["assessment.service.name"] == "app-b-engine") and
      ($b_server.labels["assessment.service.version"] == $app_b_sha) and
      ($a_server.labels["assessment.cloud.region"] == $a_client.labels["assessment.cloud.region"]) and
      ($a_server.labels["assessment.cloud.region"] == $b_server.labels["assessment.cloud.region"]) and
      ($a_server.labels["assessment.k8s.cluster.name"] == $a_client.labels["assessment.k8s.cluster.name"]) and
      ($a_server.labels["assessment.k8s.cluster.name"] == $b_server.labels["assessment.k8s.cluster.name"]) and
      (
        [$a_server.labels["assessment.cloud.region"], $a_server.labels["assessment.k8s.cluster.name"]]
        == ["us-central1", "gke-risk-usc1"] or
        [$a_server.labels["assessment.cloud.region"], $a_server.labels["assessment.k8s.cluster.name"]]
        == ["us-east4", "gke-risk-use4"]
      )
    ' <<<"$trace_response" >/dev/null 2>&1; then
      trace_verified=1
      verified_trace_id="$sampled_trace_id"
      break
    fi
  sleep 5
done
((trace_verified == 1)) \
  || fail "Cloud Trace did not return an independently sampled current-version three-span chain within three minutes"
trace_summary="$(
  jq -c --arg trace_id "$verified_trace_id" '
    (.spans // []) as $spans |
    def sanitized_span($span): {
      name: $span.name,
      kind: $span.kind,
      span_id: $span.spanId,
      parent_span_id: ($span.parentSpanId // ""),
      service: $span.labels["assessment.service.name"],
      version: $span.labels["assessment.service.version"],
      region: $span.labels["assessment.cloud.region"],
      cluster: $span.labels["assessment.k8s.cluster.name"]
    };
    {
      trace_id: $trace_id,
      spans: [
        sanitized_span([$spans[]
          | select(.name == "GET /api/exchange-rates" and .kind == "RPC_SERVER")][0]),
        sanitized_span([$spans[]
          | select(.name == "GET app-b-engine/internal/exchange-rates" and .kind == "RPC_CLIENT")][0]),
        sanitized_span([$spans[]
          | select(.name == "GET /internal/exchange-rates" and .kind == "RPC_SERVER")][0])
      ]
    }
  ' <<<"$trace_response"
)"
printf 'cloud_trace_chain=%s\n' "$trace_summary"
printf 'Cloud Trace: PASS trace %s proves current App A -> App B identity, cell, and exact parent chain.\n' \
  "$verified_trace_id"

profile_verified=0
profile_summary=""
cutoff="$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"
fields='profiles(deployment,startTime,profileType,duration,labels),nextPageToken'
profile_page_cap=20

list_profile_metadata() {
  local accumulated='{"profiles":[],"pages":0}'
  local next_token=""
  local page_response
  local page_token=""
  local page_number
  local request_args

  for ((page_number = 1; page_number <= profile_page_cap; page_number++)); do
    request_args=(
      --get
      --data-urlencode 'pageSize=1000'
      --data-urlencode "fields=$fields"
    )
    if [[ -n "$page_token" ]]; then
      request_args+=(--data-urlencode "pageToken=$page_token")
    fi
    page_response="$(gcp_get "${request_args[@]}" \
      "https://cloudprofiler.googleapis.com/v2/projects/$PROJECT_ID/profiles")"
    jq -e '
      ([.. | objects | select(has("profileBytes"))] | length == 0)
      and (((.profiles // []) | type) == "array")
      and (((.nextPageToken // "") | type) == "string")
    ' <<<"$page_response" >/dev/null \
      || fail "Profiler metadata response violated the no-profile-bytes contract"
    accumulated="$(
      jq -cn --argjson prior "$accumulated" --argjson page "$page_response" '
        {
          profiles: ($prior.profiles + ($page.profiles // [])),
          pages: ($prior.pages + 1)
        }
      '
    )"
    next_token="$(jq -r '.nextPageToken // empty' <<<"$page_response")"
    if [[ -z "$next_token" ]]; then
      printf '%s\n' "$accumulated"
      return 0
    fi
    [[ "$next_token" != *$'\n'* && ${#next_token} -le 4096 ]] \
      || fail "Profiler returned an invalid pagination token"
    [[ "$next_token" != "$page_token" ]] \
      || fail "Profiler repeated a pagination token"
    page_token="$next_token"
  done
  fail "Profiler metadata exceeded the finite $profile_page_cap-page safety cap"
}

for _ in $(seq 1 60); do
  profile_response="$(list_profile_metadata)"
  profile_summary="$(jq -c \
    --arg project "$PROJECT_ID" --arg sha "$app_a_sha" --arg cutoff "$cutoff" '
    [ .profiles[]?
      | select(.deployment.projectId == $project)
      | select(.deployment.target == "app-a-gateway")
      | select(.deployment.labels.version == $sha)
      | select(.startTime >= $cutoff)
      | {target:.deployment.target,version:.deployment.labels.version,
         region:(.deployment.labels.region // .deployment.labels.zone // ""),
         startTime,profileType,duration}
    ] | sort_by(.startTime)
  ' <<<"$profile_response")"
  if jq -e '
    length > 0 and
    (map(.profileType) | any(. == "CPU")) and
    (map(.profileType) | any(. == "HEAP" or . == "WALL")) and
    all(.[]; .target == "app-a-gateway" and (.version | test("^[0-9a-f]{40}$")))
  ' <<<"$profile_summary" >/dev/null; then
    profile_verified=1
    break
  fi
  sleep 10
done
((profile_verified == 1)) \
  || fail "Cloud Profiler did not return recent current-version CPU plus HEAP/WALL profiles within ten minutes"
profile_evidence_summary="$(
  jq -c '
    sort_by(.region, .profileType, .startTime)
    | group_by([.region, .profileType])
    | map(last)
    | sort_by(.region, .profileType)
  ' <<<"$profile_summary"
)"
printf 'cloud_profiler_metadata_pages=%s\n' "$(jq -r '.pages' <<<"$profile_response")"
printf 'cloud_profiler_profiles=%s\n' "$profile_evidence_summary"
printf '%s\n' \
  'Cloud Profiler: PASS recent App A current-version CPU plus HEAP/WALL metadata (profile bytes were never requested or stored).'
rm -f -- "$headers" "$body"
trap cleanup EXIT INT TERM
printf '%s\n' \
  'Cloud observability live gate: PASS (direct keyless OTLP, exact distributed parent chain, and current App A profiles).'

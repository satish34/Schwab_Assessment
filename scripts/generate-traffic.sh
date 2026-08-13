#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
app_a_namespace="currency-app-a"
app_b_namespace="currency-app-b"
runtime_dir="$repo_root/.tmp"
kubeconfig="$runtime_dir/kubeconfig-verifier"
manifest="$runtime_dir/bigquery-seed.json"
success_rounds="${TRAFFIC_SUCCESS_ROUNDS:-34}"
request_interval_seconds="${TRAFFIC_INTERVAL_SECONDS:-1}"
fault_timeout_seconds="${FAULT_ACTIVATION_TIMEOUT_SECONDS:-180}"
recovery_timeout_seconds="${FAULT_RECOVERY_TIMEOUT_SECONDS:-240}"
backend_timeout_seconds="${BACKEND_RECOVERY_TIMEOUT_SECONDS:-180}"
app_b_token_audience="https://app-b-engine.schwab-assessment.internal"
app_b_internal_url="http://app-b-engine.currency-app-b.svc.cluster.local:8080/internal/exchange-rates"
metadata_identity_url="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity"
work_dir=""
events_file=""
active_port_forward_pid=""
local_port=""
request_counter=0
request_status=""
request_correlation_id=""
request_trace_id=""
request_traceparent=""
request_response_file=""
request_region=""
request_cluster=""
success_traffic_duration_seconds=0
declare -A needs_restore=()

fail() {
  printf 'generate-traffic: %s\n' "$*" >&2
  exit 1
}

stop_port_forward() {
  if [[ -n "$active_port_forward_pid" ]]; then
    kill "$active_port_forward_pid" 2>/dev/null || true
    wait "$active_port_forward_pid" 2>/dev/null || true
    active_port_forward_pid=""
    local_port=""
  fi
}

restore_fault_best_effort() {
  local context="$1"
  local attempt

  for attempt in 1 2 3; do
    if timeout --foreground --signal=INT --kill-after=10s 1m \
      kubectl --context="$context" --namespace="$app_b_namespace" \
        --request-timeout=30s apply -f "$repo_root/k8s/faults/healthy.yaml" \
        >/dev/null 2>&1 \
      && validate_fault_config "$context" 0.0; then
      return 0
    fi
    sleep 2
  done
  return 1
}

cleanup() {
  local exit_code=$?
  local context
  local restore_failed=0

  trap - EXIT HUP INT TERM
  stop_port_forward
  for context in "${!needs_restore[@]}"; do
    if [[ "${needs_restore[$context]}" == "1" ]]; then
      if ! restore_fault_best_effort "$context"; then
        restore_failed=1
        printf 'generate-traffic: ERROR: three automatic restore attempts failed for %s.\n' \
          "$context" >&2
        printf 'Run: KUBECONFIG=%q kubectl --context=%q --namespace=%q apply -f %q\n' \
          "${KUBECONFIG:-$kubeconfig}" "$context" "$app_b_namespace" \
          "$repo_root/k8s/faults/healthy.yaml" >&2
      fi
    fi
  done
  ((restore_failed == 0)) || exit_code=1
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/generate-traffic.*)
        rm -f -- "$work_dir"/*
        rmdir -- "$work_dir" 2>/dev/null || true
        ;;
    esac
  fi
  exit "$exit_code"
}
trap cleanup EXIT HUP INT TERM

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  exit 2
fi

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

app_a_sha="$1"
app_b_sha="$2"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project, received $PROJECT_ID"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"
[[ "$app_a_sha" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$app_b_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "both image versions must be full lowercase 40-character Git SHAs"
[[ "$success_rounds" =~ ^[0-9]+$ ]] \
  && ((success_rounds >= 1 && success_rounds <= 60)) \
  || fail "TRAFFIC_SUCCESS_ROUNDS must be between 1 and 60"
[[ "$request_interval_seconds" =~ ^[0-9]+$ ]] \
  && ((request_interval_seconds <= 10)) \
  || fail "TRAFFIC_INTERVAL_SECONDS must be between 0 and 10"
[[ "$fault_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((fault_timeout_seconds >= 60 && fault_timeout_seconds <= 600)) \
  || fail "FAULT_ACTIVATION_TIMEOUT_SECONDS must be between 60 and 600"
[[ "$recovery_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((recovery_timeout_seconds >= 60 && recovery_timeout_seconds <= 900)) \
  || fail "FAULT_RECOVERY_TIMEOUT_SECONDS must be between 60 and 900"
[[ "$backend_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((backend_timeout_seconds >= 60 && backend_timeout_seconds <= 600)) \
  || fail "BACKEND_RECOVERY_TIMEOUT_SECONDS must be between 60 and 600"
planned_success_seconds=$((success_rounds * 9 * request_interval_seconds))
((planned_success_seconds >= 300 && planned_success_seconds <= 600)) \
  || fail "the mixed success phase must be between five and ten minutes"

for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] \
    || fail "$override_name must be unset so the named gcloud account is authoritative"
done

for command_name in curl gcloud git jq kubectl od sed terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
for required_file in \
  "$repo_root/k8s/faults/healthy.yaml" \
  "$repo_root/k8s/faults/unavailable.yaml" \
  "$repo_root/testdata/expected-exchange-rates.json"; do
  [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done
for sha in "$app_a_sha" "$app_b_sha"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null \
    || fail "Git SHA $sha is not a commit in this repository"
done

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

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"
[[ -f "$kubeconfig" ]] \
  || fail "the isolated kubeconfig is missing; run the regional workload gate first"
case "$(uname -s)" in
  MINGW* | MSYS*) KUBECONFIG="$(cygpath -w "$kubeconfig")" ;;
  *) KUBECONFIG="$kubeconfig" ;;
esac
export KUBECONFIG

contexts="$(kubectl config get-contexts -o name | tr -d '\r' | sort)"
[[ "$contexts" == $'gke-risk-usc1\ngke-risk-use4' ]] \
  || fail "the isolated kubeconfig does not contain exactly the two frozen contexts"

validate_workload_sha() {
  local context="$1"
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$app_a_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$app_b_sha"
  local app_a_deployments
  local app_b_deployment

  app_a_deployments="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=30s \
      get deployments --selector='app=app-a-gateway' -o json
  )"
  app_b_deployment="$(
    kubectl --context="$context" --namespace="$app_b_namespace" --request-timeout=30s \
      get deployment app-b-engine -o json
  )"
  jq -e --arg image "$app_a_image" --arg version "$app_a_sha" '
    def literal_env($item; $name; $value):
      [$item.spec.template.spec.containers[0].env[]?
        | select(.name == $name and .value == $value)] | length == 1;
    (.items | length) == 3 and
    all(.items[];
      (.status.observedGeneration == .metadata.generation) and
      (.status.replicas // 0) >= 1 and (.status.replicas // 0) <= 2 and
      (.status.updatedReplicas == .status.replicas) and
      (.status.readyReplicas == .status.replicas) and
      ((.status.unavailableReplicas // 0) == 0) and
      ([.spec.template.spec.containers[].image] == [$image]) and
      literal_env(.; "SERVICE_VERSION"; $version) and
      literal_env(.; "APP_B_BASE_URL"; "http://app-b-engine.currency-app-b.svc.cluster.local:8080")) and
    all(.items[].spec.template.spec.containers[].image;
      (contains(":latest") | not))
  ' <<<"$app_a_deployments" >/dev/null \
    || fail "$context App A is not ready on exact immutable SHA $app_a_sha"

  jq -e --arg image "$app_b_image" --arg version "$app_b_sha" '
    def literal_env($name; $value):
      [.spec.template.spec.containers[0].env[]?
        | select(.name == $name and .value == $value)] | length == 1;
    (.metadata.name == "app-b-engine") and
      (.status.observedGeneration == .metadata.generation) and
      (.status.replicas // 0) >= 2 and (.status.replicas // 0) <= 6 and
      (.status.updatedReplicas == .status.replicas) and
      (.status.readyReplicas == .status.replicas) and
      ((.status.unavailableReplicas // 0) == 0) and
      ([.spec.template.spec.containers[].image] == [$image]) and
      literal_env("SERVICE_VERSION"; $version) and
      all(.spec.template.spec.containers[].image; (contains(":latest") | not))
  ' <<<"$app_b_deployment" >/dev/null \
    || fail "$context App B is not ready on exact immutable SHA $app_b_sha"
}

validate_fault_config() {
  local context="$1"
  local expected_rate="$2"
  local config

  config="$(
    kubectl --context="$context" --namespace="$app_b_namespace" --request-timeout=30s \
      get configmap risk-faults -o json
  )"
  jq -e --argjson rate "$expected_rate" '
    (.data["faults.json"] | fromjson) == {
      "injected_latency_ms": 0,
      "injected_error_rate": $rate
    }
  ' <<<"$config" >/dev/null
}

for context in gke-risk-usc1 gke-risk-use4; do
  MSYS_NO_PATHCONV=1 kubectl --context="$context" --request-timeout=20s \
    get --raw=/version >/dev/null
  validate_workload_sha "$context"
  validate_fault_config "$context" 0.0 \
    || fail "$context must start on the checked-in healthy fault profile"
  needs_restore[$context]=0
done

lb_outputs="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    terraform -chdir=infra/30-lb output -json
)"
public_endpoint="$(jq -r '.public_endpoint.value // ""' <<<"$lb_outputs")"
jq -e --arg endpoint "$public_endpoint" '
  (.backend_service_name.value == "risk-app-a-gateway-backend") and
  (.public_endpoint.value == $endpoint) and
  (.tls_enabled.value == true) and
  ($endpoint == "https://satish.store") and
  (.forwarding_rule_names.value.http == null) and
  (.forwarding_rule_names.value.https == "risk-app-a-https") and
  ((.neg_backends.value | length) == 6)
' <<<"$lb_outputs" >/dev/null \
  || fail "the current 30-lb outputs do not describe the frozen HTTPS-only public edge"

mkdir -p "$runtime_dir"
git check-ignore --quiet -- "$manifest" \
  || fail "the runtime seed manifest path is not ignored by Git"
# A failed new run must not leave an older run eligible for verification.
rm -f -- "$manifest"
work_dir="$(mktemp -d "$runtime_dir/generate-traffic.XXXXXX")"
events_file="$work_dir/events.ndjson"
: >"$events_file"

random_hex() {
  local bytes="$1"
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

random_uuid() {
  local value
  value="$(random_hex 16)"
  printf '%s-%s-%s-%s-%s' \
    "${value:0:8}" "${value:8:4}" "${value:12:4}" \
    "${value:16:4}" "${value:20:12}"
}

prepare_request_context() {
  local span_id

  request_counter=$((request_counter + 1))
  request_correlation_id="$(random_uuid)"
  request_trace_id="$(random_hex 16)"
  span_id="$(random_hex 8)"
  [[ "$request_trace_id" != "00000000000000000000000000000000" ]] \
    || request_trace_id="1${request_trace_id:1}"
  [[ "$span_id" != "0000000000000000" ]] \
    || span_id="1${span_id:1}"
  request_response_file="$work_dir/response-$request_counter.json"
  request_traceparent="00-$request_trace_id-$span_id-01"
}

issue_request() {
  local base_url="$1"
  local route="$2"

  prepare_request_context

  request_status="$(
    curl --silent --show-error --max-time 15 \
      --output "$request_response_file" --write-out '%{http_code}' \
      --request GET "$base_url$route" \
      --header 'Accept: application/json' \
      --header "x-correlation-id: $request_correlation_id" \
      --header "traceparent: $request_traceparent" \
      2>/dev/null || true
  )"
  request_region=""
  request_cluster=""
  if [[ "$request_status" == "200" ]]; then
    request_region="$(jq -r '.providedBy.region // ""' "$request_response_file")"
    request_cluster="$(jq -r '.providedBy.cluster // ""' "$request_response_file")"
  fi
}

ready_app_a_pod() {
  local context="$1"
  local pods

  pods="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=30s \
      get pods --selector='app=app-a-gateway' -o json
  )"
  jq -r '
    [
      .items[]
      | select(.metadata.deletionTimestamp == null)
      | select(.status.phase == "Running")
      | select(.spec.serviceAccountName == "app-a-gateway")
      | select(any(.status.conditions[]?;
          .type == "Ready" and .status == "True"))
      | select(any(.status.containerStatuses[]?;
          .name == "app-a-gateway" and .ready == true))
    ]
    | sort_by(.metadata.name)
    | .[0].metadata.name // ""
  ' <<<"$pods"
}

issue_authenticated_app_b_request() {
  local context="$1"
  local pod exec_output response_body

  prepare_request_context
  pod="$(ready_app_a_pod "$context")"
  [[ -n "$pod" ]] \
    || fail "$context has no ready App A Pod available for the authenticated App B probe"

  # The identity token remains inside the Pod: the shell writes it only to a
  # mode-0600 wget config and the exec stream returns only status and body.
  if ! exec_output="$(
      timeout --foreground --signal=INT --kill-after=5s 30s \
        kubectl --context="$context" --namespace="$app_a_namespace" \
          --request-timeout=25s exec "$pod" --container=app-a-gateway -- \
          sh -eu -c '
            audience="$1"
            metadata_url="$2"
            app_b_url="$3"
            correlation_id="$4"
            traceparent="$5"
            token=""
            umask 077
            body="$(mktemp /tmp/app-b-evidence.XXXXXX)"
            headers="$(mktemp /tmp/app-b-headers.XXXXXX)"
            auth_config="$(mktemp /tmp/app-b-wget.XXXXXX)"
            cleanup_probe() {
              token=""
              rm -f -- "$body" "$headers" "$auth_config"
            }
            trap cleanup_probe EXIT
            trap "cleanup_probe; exit 1" HUP INT TERM

            encoded_audience="$(printf "%s" "$audience" | sed "s/:/%3A/g; s#/#%2F#g")"
            if ! token="$(
              timeout 15s wget --quiet --no-proxy --timeout=10 --tries=2 \
                --header="Metadata-Flavor: Google" --output-document=- \
                "$metadata_url?audience=$encoded_audience&format=full"
            )"; then
              exit 70
            fi
            case "$token" in
              "" | *[!A-Za-z0-9._-]* | .* | *..* | *. | *.*.*.*)
                exit 71
                ;;
              *.*.*) ;;
              *) exit 71 ;;
            esac
            [ "${#token}" -le 16384 ] || exit 71

            printf "header = Authorization: Bearer %s\n" "$token" >"$auth_config"
            token=""
            set +e
            timeout 20s wget --quiet --no-proxy --timeout=15 --tries=1 \
              --config="$auth_config" --server-response --output-document="$body" \
              --header="Accept: application/json" \
              --header="x-correlation-id: $correlation_id" \
              --header="traceparent: $traceparent" \
              "$app_b_url" 2>"$headers"
            wget_status=$?
            set -e
            status="$(sed -n "s/^[[:space:]]*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p" "$headers" | tail -n 1)"
            case "$status" in
              [0-9][0-9][0-9]) ;;
              *) exit 73 ;;
            esac
            case "$status:$wget_status" in
              200:0 | 503:8) ;;
              *) exit 72 ;;
            esac
            cat "$body"
            printf "\n%s\n" "$status"
          ' app-b-evidence \
          "$app_b_token_audience" "$metadata_identity_url" \
          "$app_b_internal_url" "$request_correlation_id" \
          "$request_traceparent"
    )"; then
    fail "$context authenticated in-Pod App B request failed closed"
  fi

  [[ "$exec_output" == *$'\n'* ]] \
    || fail "$context authenticated App B request returned an invalid exec result"
  request_status="${exec_output##*$'\n'}"
  response_body="${exec_output%$'\n'*}"
  [[ "$request_status" =~ ^[0-9]{3}$ ]] \
    || fail "$context authenticated App B request returned an invalid HTTP status"
  printf '%s' "$response_body" >"$request_response_file"

  request_region=""
  request_cluster=""
  if [[ "$request_status" == "200" ]]; then
    request_region="$(jq -r '.providedBy.region // ""' "$request_response_file")"
    request_cluster="$(jq -r '.providedBy.cluster // ""' "$request_response_file")"
  fi
}

record_event() {
  local path="$1"
  local target_service="$2"
  local kind="$3"
  local region="$4"
  local cluster="$5"
  local decision="$6"

  jq -nc \
    --arg path "$path" \
    --arg target_service "$target_service" \
    --arg kind "$kind" \
    --arg region "$region" \
    --arg cluster "$cluster" \
    --arg decision "$decision" \
    --arg correlation_id "$request_correlation_id" \
    --arg trace_id "$request_trace_id" \
    --argjson http_status "$request_status" '
      {
        path: $path,
        target_service: $target_service,
        kind: $kind,
        region: $region,
        cluster: $cluster,
        decision: $decision,
        correlation_id: $correlation_id,
        trace_id: $trace_id,
        http_status: $http_status
      }
    ' >>"$events_file"
}

assert_success_response() {
  local expected_region="${1:-}"
  local expected_cluster="${2:-}"

  [[ "$request_status" == "200" ]] \
    || fail "synthetic request returned HTTP ${request_status:-<none>}"
  jq -e \
    --slurpfile expected "$repo_root/testdata/expected-exchange-rates.json" \
    --arg version "$app_b_sha" '
      (keys == ["baseCurrency", "disclaimer", "providedBy", "rateSnapshots"]) and
      (.rateSnapshots | length == 10) and
      all(.rateSnapshots[]; keys == ["EUR", "GBP", "JPY"]) and
      (.providedBy | keys == ["cluster", "region", "service", "version"]) and
      .baseCurrency == $expected[0].baseCurrency and
      .rateSnapshots == $expected[0].rateSnapshots and
      .disclaimer == $expected[0].disclaimer and
      .providedBy.service == $expected[0].providedBy.service and
      .providedBy.version == $version and
      ((.providedBy.region == "us-central1" and
        .providedBy.cluster == "gke-risk-usc1") or
       (.providedBy.region == "us-east4" and
        .providedBy.cluster == "gke-risk-use4"))
    ' "$request_response_file" >/dev/null \
    || fail "HTTP 200 response does not match the immutable exchange-rate contract"
  if [[ -n "$expected_region" ]]; then
    [[ "$request_region" == "$expected_region" \
      && "$request_cluster" == "$expected_cluster" ]] \
      || fail "direct request escaped its expected cell"
  fi
}

start_port_forward() {
  local context="$1"
  local resource="$2"
  local log_file="$work_dir/port-forward-${context}-${request_counter}.log"
  local deadline

  stop_port_forward
  : >"$log_file"
  kubectl --context="$context" --namespace="$app_a_namespace" \
    port-forward --address=127.0.0.1 "$resource" :8080 \
    >"$log_file" 2>&1 &
  active_port_forward_pid=$!
  deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    local_port="$(
      tr -d '\r' <"$log_file" \
        | sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) -> 8080$/\1/p' \
        | head -n 1
    )"
    [[ -n "$local_port" ]] && return 0
    if ! kill -0 "$active_port_forward_pid" 2>/dev/null; then
      cat "$log_file" >&2
      fail "$context port-forward to $resource exited before it became ready"
    fi
    sleep 1
  done
  cat "$log_file" >&2
  fail "$context port-forward to $resource did not become ready within 30s"
}

seed_successes() {
  local path="$1"
  local base_url="$2"
  local expected_region="${3:-}"
  local expected_cluster="${4:-}"
  local round sample attempt

  for ((round = 1; round <= success_rounds; round++)); do
    for sample in 1 2 3; do
      for attempt in 1 2 3; do
        issue_request "$base_url" /api/exchange-rates
        [[ "$request_status" == "200" ]] && break
        case "$request_status" in
          "" | 000 | 503 | 504) sleep 2 ;;
          *) fail "synthetic request returned unexpected HTTP $request_status" ;;
        esac
      done
      [[ "$request_status" == "200" ]] \
        || fail "synthetic request did not recover after three bounded attempts"
      assert_success_response "$expected_region" "$expected_cluster"
      record_event "$path" app-a-gateway success \
        "$request_region" "$request_cluster" RATES_RETURNED
      sleep "$request_interval_seconds"
    done
  done
}

apply_fault_profile() {
  local context="$1"
  local profile="$2"
  local expected_rate="$3"

  timeout --foreground --signal=INT --kill-after=10s 1m \
    kubectl --context="$context" --namespace="$app_b_namespace" \
      --request-timeout=30s apply -f "$repo_root/k8s/faults/$profile.yaml" \
      >/dev/null
  validate_fault_config "$context" "$expected_rate" \
    || fail "$context did not accept the $profile fault profile"
}

wait_for_direct_status() {
  local context="$1"
  local resource="$2"
  local route="$3"
  local expected_status="$4"
  local deadline="$5"
  local expected_region="$6"
  local expected_cluster="$7"

  start_port_forward "$context" "$resource"
  while ((SECONDS < deadline)); do
    issue_request "http://127.0.0.1:$local_port" "$route"
    if [[ "$request_status" == "$expected_status" ]]; then
      if [[ "$expected_status" == "200" ]]; then
        assert_success_response "$expected_region" "$expected_cluster"
      fi
      stop_port_forward
      return 0
    fi
    case "$request_status" in
      200|503) ;;
      *)
        stop_port_forward
        fail "$context $resource returned unexpected HTTP ${request_status:-<none>}"
        ;;
    esac
    sleep 2
  done
  stop_port_forward
  return 1
}

wait_for_authenticated_app_b_status() {
  local context="$1"
  local expected_status="$2"
  local deadline="$3"
  local expected_region="$4"
  local expected_cluster="$5"

  while ((SECONDS < deadline)); do
    issue_authenticated_app_b_request "$context"
    if [[ "$request_status" == "$expected_status" ]]; then
      if [[ "$expected_status" == "200" ]]; then
        assert_success_response "$expected_region" "$expected_cluster"
      fi
      return 0
    fi
    case "$request_status" in
      200 | 503) ;;
      *)
        fail "$context authenticated App B probe returned unexpected HTTP ${request_status:-<none>}"
        ;;
    esac
    sleep 2
  done
  return 1
}

wait_for_cell_health() {
  local context="$1"
  local deadline="$2"
  local response_file="$work_dir/cell-health-$context.json"
  local status=""

  start_port_forward "$context" service/app-a-gateway
  while ((SECONDS < deadline)); do
    status="$(
      curl --silent --show-error --max-time 5 \
        --output "$response_file" --write-out '%{http_code}' \
        "http://127.0.0.1:$local_port/health/cell" 2>/dev/null || true
    )"
    if [[ "$status" == "200" ]] \
      && jq -e '.status == "HEALTHY"' "$response_file" >/dev/null 2>&1; then
      stop_port_forward
      return 0
    fi
    sleep 2
  done
  stop_port_forward
  return 1
}

wait_for_backend_region() {
  local region="$1"
  local deadline="$2"
  local health_json healthy

  while ((SECONDS < deadline)); do
    if ! health_json="$(
        timeout --foreground --signal=INT --kill-after=10s 1m \
          gcloud --configuration="$GCLOUD_CONFIGURATION" \
            --account="$expected_account" --project="$PROJECT_ID" \
            compute backend-services get-health \
            risk-app-a-gateway-backend --global --format=json
      )"; then
      sleep 5
      continue
    fi
    if ! healthy="$(
        jq --arg region "$region" '
          [ .[] as $backend |
            (($backend.backend // "") |
              capture("/zones/(?<zone>[^/]+)/").zone) as $zone |
            select($zone | startswith($region + "-")) |
            select(any($backend.status.healthStatus[]?;
              .healthState == "HEALTHY")) |
            $zone
          ] | unique | length
        ' <<<"$health_json"
      )"; then
      sleep 5
      continue
    fi
    ((healthy == 3)) && return 0
    sleep 5
  done
  return 1
}

exercise_controlled_error() {
  local context="$1"
  local expected_region="$2"
  local expected_cluster="$3"
  local fault_deadline recovery_deadline sample

  needs_restore[$context]=1
  apply_fault_profile "$context" unavailable 1.0
  fault_deadline=$((SECONDS + fault_timeout_seconds))

  # Probe App B directly from an App A Pod so every App B evidence identifier
  # corresponds to a request that reached App B, independent of App A health
  # caching and circuit-breaker behavior.
  for sample in 1 2; do
    wait_for_authenticated_app_b_status "$context" 503 "$fault_deadline" \
      "$expected_region" "$expected_cluster" \
      || fail "$context App B did not return the authenticated controlled error within ${fault_timeout_seconds}s"
    record_event cell app-b-engine controlled_error \
      "$expected_region" "$expected_cluster" ""
  done

  wait_for_direct_status "$context" service/app-a-gateway /api/exchange-rates 503 \
    "$fault_deadline" "$expected_region" "$expected_cluster" \
    || fail "$context App A did not surface the controlled dependency error"
  record_event cell app-a-gateway controlled_error \
    "$expected_region" "$expected_cluster" ""

  apply_fault_profile "$context" healthy 0.0
  recovery_deadline=$((SECONDS + recovery_timeout_seconds))
  for sample in 1 2; do
    wait_for_authenticated_app_b_status "$context" 200 "$recovery_deadline" \
      "$expected_region" "$expected_cluster" \
      || fail "$context App B did not recover for the authenticated in-Pod caller within ${recovery_timeout_seconds}s"
    record_event cell app-b-engine success \
      "$expected_region" "$expected_cluster" RATES_RETURNED
  done

  wait_for_direct_status "$context" service/app-a-gateway /api/exchange-rates 200 \
    "$recovery_deadline" "$expected_region" "$expected_cluster" \
    || fail "$context App A did not recover within ${recovery_timeout_seconds}s"
  record_event cell app-a-gateway success \
    "$expected_region" "$expected_cluster" RATES_RETURNED
  wait_for_cell_health "$context" "$recovery_deadline" \
    || fail "$context /health/cell did not recover within ${recovery_timeout_seconds}s"
  wait_for_backend_region "$expected_region" \
    "$((SECONDS + backend_timeout_seconds))" \
    || fail "$expected_region did not return to one healthy endpoint per zone"
  needs_restore[$context]=0
  printf '%s controlled error was observed and fully restored.\n' "$context"
}

started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
run_id="$(random_uuid)"

wait_for_backend_region us-central1 "$((SECONDS + backend_timeout_seconds))" \
  || fail "us-central1 does not have one healthy edge endpoint per zone"
wait_for_backend_region us-east4 "$((SECONDS + backend_timeout_seconds))" \
  || fail "us-east4 does not have one healthy edge endpoint per zone"
success_phase_started=$SECONDS
seed_successes global "$public_endpoint"

start_port_forward gke-risk-usc1 service/app-a-gateway
seed_successes cell "http://127.0.0.1:$local_port" us-central1 gke-risk-usc1
stop_port_forward

start_port_forward gke-risk-use4 service/app-a-gateway
seed_successes cell "http://127.0.0.1:$local_port" us-east4 gke-risk-use4
stop_port_forward
success_traffic_duration_seconds=$((SECONDS - success_phase_started))
((success_traffic_duration_seconds >= 300)) \
  || fail "the mixed success phase ended before five minutes"

exercise_controlled_error gke-risk-usc1 us-central1 gke-risk-usc1
exercise_controlled_error gke-risk-use4 us-east4 gke-risk-use4

completed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
manifest_candidate="$work_dir/bigquery-seed.json"
jq -s \
  --arg run_id "$run_id" \
  --arg project_id "$PROJECT_ID" \
  --arg configuration "$GCLOUD_CONFIGURATION" \
  --arg app_a_sha "$app_a_sha" \
  --arg app_b_sha "$app_b_sha" \
  --arg public_endpoint "$public_endpoint" \
  --arg started_at "$started_at" \
  --arg completed_at "$completed_at" \
  --argjson success_duration "$success_traffic_duration_seconds" '
    {
      schema_version: 3,
      run_id: $run_id,
      project_id: $project_id,
      gcloud_configuration: $configuration,
      app_a_sha: $app_a_sha,
      app_b_sha: $app_b_sha,
      public_endpoint: $public_endpoint,
      started_at: $started_at,
      completed_at: $completed_at,
      success_traffic_duration_seconds: $success_duration,
      events: .
    }
  ' "$events_file" >"$manifest_candidate"

jq -e '
  (.success_traffic_duration_seconds >= 300) and
  (.events | length) >= 20 and
  ([.events[].correlation_id] | length == (unique | length)) and
  ([.events[].trace_id] | length == (unique | length)) and
  all(.events[];
    (.correlation_id | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.trace_id | test("^[0-9a-f]{32}$")) and
    (.region == "us-central1" or .region == "us-east4") and
    (.cluster == "gke-risk-usc1" or .cluster == "gke-risk-use4") and
    ((.kind == "success" and .http_status == 200 and .decision == "RATES_RETURNED") or
     (.kind == "controlled_error" and .http_status >= 500 and .decision == "")))
' "$manifest_candidate" >/dev/null \
  || fail "the generated traffic manifest is incomplete"

mv -f -- "$manifest_candidate" "$manifest"
printf 'Generated %s bounded exchange-rate requests for run %s at App A %s / App B %s; both cell faults were restored.\n' \
  "$(jq '.events | length' "$manifest")" "$run_id" "$app_a_sha" "$app_b_sha"

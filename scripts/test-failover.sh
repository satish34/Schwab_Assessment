#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
app_a_namespace="currency-app-a"
app_b_namespace="currency-app-b"
backend_name="risk-app-a-gateway-backend"
runtime_dir="$repo_root/.tmp"
evidence_dir="$repo_root/evidence"

work_dir=""
traffic_dir=""
kubeconfig=""
kubeconfig_candidate=""
active_port_forward_pid=""
active_port_forward_log=""
active_local_port=""
traffic_pid=""
traffic_stop_file=""
fault_target_context=""
fault_target_region=""
surviving_context=""
surviving_region=""
restore_required=0
preserve_recovery_context=0
global_deadline=0
backend_summary="[]"

fail() {
  printf 'test-failover: %s\n' "$*" >&2
  exit 1
}

now_epoch_ms() {
  local value

  value="$(date -u +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]{13}$ ]]; then
    printf '%s' "$value"
  else
    printf '%s000' "$(date -u +%s)"
  fi
}

milliseconds_as_seconds() {
  awk -v value="$1" 'BEGIN { printf "%.3f", value / 1000 }'
}

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

stop_port_forward() {
  if [[ -n "$active_port_forward_pid" ]]; then
    kill "$active_port_forward_pid" 2>/dev/null || true
    wait "$active_port_forward_pid" 2>/dev/null || true
    active_port_forward_pid=""
    active_local_port=""
  fi
}

validate_fault_config() {
  local context="$1"
  local expected_rate="$2"
  local config

  config="$(
    kubectl --context="$context" --namespace="$app_b_namespace" \
      --request-timeout=30s get configmap risk-faults -o json
  )" || return 1
  jq -e --argjson rate "$expected_rate" '
    (.data["faults.json"] | fromjson) == {
      "injected_latency_ms": 0,
      "injected_error_rate": $rate
    }
  ' <<<"$config" >/dev/null
}

validate_fault_manifest() {
  local path="$1"
  local expected_sha256="$2"
  local actual_sha256

  actual_sha256="$(sha256sum "$path" | awk '{print $1}')" || return 1
  [[ "$actual_sha256" == "$expected_sha256" ]]
}

restore_fault_best_effort() {
  local attempt

  [[ -n "$fault_target_context" && -f "$repo_root/k8s/faults/healthy.yaml" ]] \
    || return 1

  for attempt in 1 2 3; do
    if timeout --foreground --signal=INT --kill-after=10s 1m \
      kubectl --context="$fault_target_context" --namespace="$app_b_namespace" \
        --request-timeout=30s apply \
        -f "$repo_root/k8s/faults/healthy.yaml" >/dev/null 2>&1 \
      && validate_fault_config "$fault_target_context" 0.0; then
      return 0
    fi
    sleep 2
  done
  return 1
}

stop_traffic() {
  if [[ -n "$traffic_pid" ]]; then
    if [[ -n "$traffic_stop_file" ]]; then
      : >"$traffic_stop_file"
    fi
    wait "$traffic_pid" 2>/dev/null || true
    traffic_pid=""
  fi
}

cleanup() {
  local exit_code=$?

  trap - EXIT HUP INT TERM
  set +e
  stop_port_forward
  if ((restore_required == 1)); then
    if restore_fault_best_effort; then
      printf 'test-failover: restored the healthy fault profile in %s during cleanup.\n' \
        "$fault_target_context" >&2
    else
      preserve_recovery_context=1
      printf 'test-failover: ERROR: three automatic restore attempts failed for %s.\n' \
        "${fault_target_context:-<not-selected>}" >&2
      printf 'Recovery context preserved at %s; run: KUBECONFIG=%q kubectl --context=%q --namespace=%q apply -f %q\n' \
        "${kubeconfig:-<unknown>}" "$kubeconfig" "$fault_target_context" \
        "$app_b_namespace" "$repo_root/k8s/faults/healthy.yaml" >&2
      exit_code=1
    fi
  fi
  stop_traffic

  if ((preserve_recovery_context == 0)) \
    && [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi
  if ((preserve_recovery_context == 0)) \
    && [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/test-failover.*)
        if [[ -n "$traffic_dir" && -d "$traffic_dir" ]]; then
          rm -f -- "$traffic_dir"/meta-*.json \
            "$traffic_dir"/meta-*.tmp "$traffic_dir"/response-*.json \
            "$traffic_dir"/row-*.csv "$traffic_dir"/row-*.tmp \
            "$traffic_dir"/stop
          rmdir -- "$traffic_dir" 2>/dev/null || true
        fi
        rm -f -- "$work_dir"/*
        rmdir -- "$work_dir" 2>/dev/null || true
        ;;
    esac
  fi

  exit "$exit_code"
}

set_kubeconfig() {
  local path="$1"

  case "$(uname -s)" in
    MINGW*|MSYS*) KUBECONFIG="$(cygpath -w "$path")" ;;
    *) KUBECONFIG="$path" ;;
  esac
  export KUBECONFIG
}

prepare_context() {
  local context="$1"
  local cluster="$2"
  local region="$3"
  local source_context

  timeout --foreground --signal=INT --kill-after=10s 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      container clusters get-credentials "$cluster" --region="$region"

  source_context="$(kubectl config current-context | tr -d '\r')"
  [[ -n "$source_context" ]] \
    || fail "gcloud did not create a context for $cluster"
  if [[ "$source_context" != "$context" ]]; then
    kubectl config rename-context "$source_context" "$context" >/dev/null
  fi
}

prepare_kubeconfig() {
  local contexts

  kubeconfig_candidate="$(mktemp "$work_dir/kubeconfig.new.XXXXXX")"
  chmod 600 "$kubeconfig_candidate" 2>/dev/null || true
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: Config' \
    'preferences: {}' \
    'clusters: []' \
    'contexts: []' \
    'users: []' >"$kubeconfig_candidate"
  set_kubeconfig "$kubeconfig_candidate"

  prepare_context gke-risk-usc1 gke-risk-usc1 us-central1
  prepare_context gke-risk-use4 gke-risk-use4 us-east4

  contexts="$(kubectl config get-contexts -o name | tr -d '\r' | sort)"
  [[ "$contexts" == $'gke-risk-usc1\ngke-risk-use4' ]] \
    || fail "the isolated kubeconfig does not contain exactly the two frozen contexts"

  kubeconfig="$work_dir/kubeconfig"
  mv -f -- "$kubeconfig_candidate" "$kubeconfig"
  kubeconfig_candidate=""
  chmod 600 "$kubeconfig" 2>/dev/null || true
  set_kubeconfig "$kubeconfig"

  MSYS_NO_PATHCONV=1 kubectl --context=gke-risk-usc1 \
    --request-timeout=20s get --raw=/version >/dev/null
  MSYS_NO_PATHCONV=1 kubectl --context=gke-risk-use4 \
    --request-timeout=20s get --raw=/version >/dev/null
}

cell_identity() {
  local context="$1"

  case "$context" in
    gke-risk-usc1) printf '%s\t%s' us-central1 gke-risk-usc1 ;;
    gke-risk-use4) printf '%s\t%s' us-east4 gke-risk-use4 ;;
    *) return 1 ;;
  esac
}

validate_cell_resources() {
  local context="$1"
  local region cluster zone_a zone_b zone_c
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$app_a_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$app_b_sha"
  local app_a_deployments app_b_deployment app_a_runtime_config app_b_runtime_config

  IFS=$'\t' read -r region cluster < <(cell_identity "$context")
  case "$region" in
    us-central1)
      zone_a=us-central1-f
      zone_b=us-central1-b
      zone_c=us-central1-c
      ;;
    us-east4)
      zone_a=us-east4-a
      zone_b=us-east4-b
      zone_c=us-east4-c
      ;;
    *) return 1 ;;
  esac

  app_a_deployments="$(
    kubectl --context="$context" --namespace="$app_a_namespace" \
      --request-timeout=30s get deployments --selector='app=app-a-gateway' -o json
  )" || return 1
  app_b_deployment="$(
    kubectl --context="$context" --namespace="$app_b_namespace" \
      --request-timeout=30s get deployment app-b-engine -o json
  )" || return 1
  app_a_runtime_config="$(
    kubectl --context="$context" --namespace="$app_a_namespace" \
      --request-timeout=30s get configmap runtime-config -o json
  )" || return 1
  app_b_runtime_config="$(
    kubectl --context="$context" --namespace="$app_b_namespace" \
      --request-timeout=30s get configmap runtime-config -o json
  )" || return 1

  jq -e \
    --arg app_a "$app_a_image" \
    --arg app_a_version "$app_a_sha" \
    --arg zone_a "$zone_a" \
    --arg zone_b "$zone_b" \
    --arg zone_c "$zone_c" '
      def expected_zone($name):
        if $name == "app-a-gateway-a" then $zone_a
        elif $name == "app-a-gateway-b" then $zone_b
        elif $name == "app-a-gateway-c" then $zone_c
        else ""
        end;
      def literal_env($item; $name; $value):
        [$item.spec.template.spec.containers[0].env[]?
          | select(.name == $name and .value == $value)] | length == 1;
      ([.items[].metadata.name] | sort) == [
          "app-a-gateway-a", "app-a-gateway-b", "app-a-gateway-c"
        ] and
      all(.items[];
        (.metadata.generation <= (.status.observedGeneration // 0)) and
        (.spec.replicas >= 1 and .spec.replicas <= 2) and
        (.status.updatedReplicas == .spec.replicas) and
        (.status.readyReplicas == .spec.replicas) and
        (.status.availableReplicas == .spec.replicas) and
        ((.status.unavailableReplicas // 0) == 0) and
        (.spec.template.spec.nodeSelector["topology.kubernetes.io/zone"]
          == expected_zone(.metadata.name)) and
        ([.spec.template.spec.containers[].image] == [$app_a]) and
        literal_env(.; "SERVICE_VERSION"; $app_a_version) and
        literal_env(.; "APP_B_BASE_URL"; "http://app-b-engine.currency-app-b.svc.cluster.local:8080")) and
      all(.items[].spec.template.spec.containers[].image;
        (contains(":latest") | not))
    ' <<<"$app_a_deployments" >/dev/null || return 1

  jq -e \
    --arg app_b "$app_b_image" \
    --arg app_b_version "$app_b_sha" '
      def literal_env($name; $value):
        [.spec.template.spec.containers[0].env[]?
          | select(.name == $name and .value == $value)] | length == 1;
      (.metadata.name == "app-b-engine") and
      (.metadata.generation <= (.status.observedGeneration // 0)) and
      (.spec.replicas >= 2 and .spec.replicas <= 6) and
      (.status.updatedReplicas == .spec.replicas) and
      (.status.readyReplicas == .spec.replicas) and
      (.status.availableReplicas == .spec.replicas) and
      ((.status.unavailableReplicas // 0) == 0) and
      ([.spec.template.spec.containers[].image] == [$app_b]) and
      literal_env("SERVICE_VERSION"; $app_b_version) and
      all(.spec.template.spec.containers[].image; (contains(":latest") | not))
    ' <<<"$app_b_deployment" >/dev/null || return 1

  for runtime_config in "$app_a_runtime_config" "$app_b_runtime_config"; do
    jq -e --arg region "$region" --arg cluster "$cluster" '
      (.data.SERVICE_REGION == $region) and
      (.data.SERVICE_CLUSTER == $cluster)
    ' <<<"$runtime_config" >/dev/null || return 1
  done

  validate_fault_config "$context" 0.0
}

start_port_forward() {
  local context="$1"
  local target_namespace="$2"
  local resource="$3"
  local safe_resource="${resource//\//-}"
  local deadline

  stop_port_forward
  active_port_forward_log="$work_dir/port-forward-$context-$safe_resource.log"
  : >"$active_port_forward_log"
  kubectl --context="$context" --namespace="$target_namespace" \
    port-forward --address=127.0.0.1 "$resource" :8080 \
    >"$active_port_forward_log" 2>&1 &
  active_port_forward_pid=$!

  deadline=$((SECONDS + 30))
  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    active_local_port="$(
      tr -d '\r' <"$active_port_forward_log" \
        | sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) -> 8080$/\1/p' \
        | head -n 1
    )"
    [[ -n "$active_local_port" ]] && return 0
    if ! kill -0 "$active_port_forward_pid" 2>/dev/null; then
      stop_port_forward
      return 1
    fi
    sleep 1
  done

  stop_port_forward
  return 1
}

curl_local_status() {
  local method="$1"
  local route="$2"
  local output_file="$3"
  local status
  local -a arguments=(
    --silent --show-error --max-time 5
    --output "$output_file" --write-out '%{http_code}'
  )

  arguments+=(--request "$method")
  status="$(
    curl "${arguments[@]}" \
      "http://127.0.0.1:$active_local_port$route" 2>/dev/null || true
  )"
  printf '%s' "${status:-000}"
}

ready_pods_json() {
  local context="$1"
  local app_label="$2"
  local target_namespace

  case "$app_label" in
    app-a-gateway) target_namespace="$app_a_namespace" ;;
    app-b-engine) target_namespace="$app_b_namespace" ;;
    *) return 1 ;;
  esac

  kubectl --context="$context" --namespace="$target_namespace" \
    --request-timeout=30s get pods --selector="app=$app_label" -o json
}

all_app_a_pods_in_state() {
  local context="$1"
  local expected_status="$2"
  local expected_body="$3"
  local image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$app_a_sha"
  local pods pod ready_status cell_status
  local response_file="$work_dir/direct-response.json"
  local pod_names=()

  pods="$(ready_pods_json "$context" app-a-gateway)" || return 1
  jq -e --arg image "$image" '
    (.items | length) >= 3 and (.items | length) <= 6 and
    all(.items[];
      (.metadata.deletionTimestamp == null) and
      (.status.phase == "Running") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      ([.spec.containers[].image] == [$image]) and
      ([.status.containerStatuses[]?.image] == [$image]) and
      all(.status.containerStatuses[]?; .ready == true))
  ' <<<"$pods" >/dev/null || return 1
  mapfile -t pod_names < <(jq -r '.items[].metadata.name' <<<"$pods" | tr -d '\r' | sort)

  for pod in "${pod_names[@]}"; do
    start_port_forward "$context" "$app_a_namespace" "pod/$pod" || return 1
    ready_status="$(curl_local_status GET /health/ready "$response_file")"
    [[ "$ready_status" == "200" ]] || {
      stop_port_forward
      return 1
    }
    cell_status="$(curl_local_status GET /health/cell "$response_file")"
    if [[ "$cell_status" != "$expected_status" ]] \
      || ! jq -e --arg status "$expected_body" '.status == $status' \
        "$response_file" >/dev/null 2>&1; then
      stop_port_forward
      return 1
    fi
    stop_port_forward
  done
}

wait_for_all_app_a_pods_state() {
  local context="$1"
  local expected_status="$2"
  local expected_body="$3"
  local timeout_seconds="$4"
  local deadline=$((SECONDS + timeout_seconds))

  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    if all_app_a_pods_in_state "$context" "$expected_status" "$expected_body"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

all_app_b_pods_ready() {
  local context="$1"
  local image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$app_b_sha"
  local pods

  pods="$(ready_pods_json "$context" app-b-engine)" || return 1
  jq -e --arg image "$image" '
    (.items | length) >= 2 and (.items | length) <= 6 and
    all(.items[];
      (.metadata.deletionTimestamp == null) and
      (.status.phase == "Running") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      ([.spec.containers[].image] == [$image]) and
      ([.status.containerStatuses[]?.image] == [$image]) and
      all(.status.containerStatuses[]?; .ready == true))
  ' <<<"$pods" >/dev/null || return 1
}

wait_for_all_app_b_pods_ready() {
  local context="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    if all_app_b_pods_ready "$context"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

summarize_backend_health_json() {
  jq -c '
    [ .[] |
      (.backend | capture(
        "/zones/(?<zone>[^/]+)/networkEndpointGroups/"
      ).zone) as $zone |
      {
        zone: $zone,
        healthy: ([.status.healthStatus[]?
          | select(.healthState == "HEALTHY")] | length),
        total: ([.status.healthStatus[]?] | length)
      }
    ] | sort_by(.zone)
  '
}

get_backend_summary() {
  local health

  health="$(
    timeout --foreground --signal=INT --kill-after=10s 1m \
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
        --account="$expected_account" --project="$PROJECT_ID" \
        compute backend-services get-health "$backend_name" \
        --global --format=json
  )" || return 1
  backend_summary="$(summarize_backend_health_json <<<"$health")" || return 1
  jq -e '
    ([.[].zone] == [
      "us-central1-b", "us-central1-c", "us-central1-f",
      "us-east4-a", "us-east4-b", "us-east4-c"
    ]) and all(.[]; .total >= 1)
  ' <<<"$backend_summary" >/dev/null
}

backend_all_cells_healthy() {
  jq -e 'all(.[]; .healthy >= 1)' <<<"$backend_summary" >/dev/null
}

backend_target_drained() {
  jq -e \
    --arg target "$fault_target_region" --arg survivor "$surviving_region" '
      all(.[] | select(.zone | startswith($target + "-")); .healthy == 0) and
      all(.[] | select(.zone | startswith($survivor + "-")); .healthy >= 1)
    ' <<<"$backend_summary" >/dev/null
}

wait_for_backend_state() {
  local mode="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    if get_backend_summary; then
      case "$mode" in
        healthy) backend_all_cells_healthy && return 0 ;;
        target-drained) backend_target_drained && return 0 ;;
        *) return 1 ;;
      esac
    fi
    sleep 5
  done
  return 1
}

compact_backend_summary() {
  jq -r 'map("\(.zone)=\(.healthy)/\(.total)") | join(" ")' <<<"$1"
}

apply_fault_profile() {
  local context="$1"
  local profile="$2"
  local expected_rate="$3"

  timeout --foreground --signal=INT --kill-after=10s 1m \
    kubectl --context="$context" --namespace="$app_b_namespace" \
      --request-timeout=30s apply \
      -f "$repo_root/k8s/faults/$profile.yaml" >/dev/null
  validate_fault_config "$context" "$expected_rate"
}

sample_public_request() {
  local sequence="$1"
  local sequence_id timestamp started_ms completed_ms correlation_id
  local response_file row_tmp row_file meta_tmp meta_file
  local metrics http_status total_seconds latency_ms status_number=0
  local region="" cluster="" valid=false

  sequence_id="$(printf '%06d' "$sequence")"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')"
  started_ms="$(now_epoch_ms)"
  correlation_id="$(random_uuid)"
  response_file="$traffic_dir/response-$sequence_id.json"
  row_tmp="$traffic_dir/row-$sequence_id.tmp"
  row_file="$traffic_dir/row-$sequence_id.csv"
  meta_tmp="$traffic_dir/meta-$sequence_id.tmp"
  meta_file="$traffic_dir/meta-$sequence_id.json"

  metrics="$(
    curl --silent --show-error --connect-timeout 2 --max-time 12 \
      --output "$response_file" --write-out $'%{http_code}\t%{time_total}' \
      --request GET "$public_endpoint/api/exchange-rates" \
      --header 'Accept: application/json' \
      --header "x-correlation-id: $correlation_id" \
      2>/dev/null || true
  )"
  IFS=$'\t' read -r http_status total_seconds <<<"$metrics"
  [[ "$http_status" =~ ^[0-9]{3}$ ]] || http_status=000
  [[ "$total_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || total_seconds=0
  latency_ms="$(awk -v value="$total_seconds" 'BEGIN { printf "%.0f", value * 1000 }')"

  if [[ "$http_status" == "200" ]] \
    && jq -e \
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
    ' "$response_file" >/dev/null 2>&1; then
    region="$(jq -r '.providedBy.region' "$response_file")"
    cluster="$(jq -r '.providedBy.cluster' "$response_file")"
    valid=true
  fi

  completed_ms="$(now_epoch_ms)"
  if [[ "$http_status" =~ ^[0-9]{3}$ ]]; then
    status_number=$((10#$http_status))
  fi
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$timestamp" "$http_status" "$latency_ms" "$region" "$cluster" \
    "$correlation_id" >"$row_tmp"
  mv -f -- "$row_tmp" "$row_file"
  jq -nc \
    --argjson sequence "$sequence" \
    --arg timestamp "$timestamp" \
    --argjson started_ms "$started_ms" \
    --argjson completed_ms "$completed_ms" \
    --argjson http_status "$status_number" \
    --argjson latency_ms "$latency_ms" \
    --arg region "$region" \
    --arg cluster "$cluster" \
    --arg correlation_id "$correlation_id" \
    --argjson valid "$valid" '
      {
        sequence: $sequence,
        timestamp: $timestamp,
        started_ms: $started_ms,
        completed_ms: $completed_ms,
        http_status: $http_status,
        latency_ms: $latency_ms,
        region: $region,
        cluster: $cluster,
        correlation_id: $correlation_id,
        valid: $valid
      }
    ' >"$meta_tmp"
  mv -f -- "$meta_tmp" "$meta_file"
  rm -f -- "$response_file"
  return 0
}

traffic_loop() {
  local max_seconds="$1"
  local deadline=$((SECONDS + max_seconds))
  local sequence=1 pid
  local pids=()

  trap - EXIT ERR
  trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; exit 143' \
    HUP INT TERM
  while [[ ! -f "$traffic_stop_file" ]] && ((SECONDS < deadline)); do
    sample_public_request "$sequence" &
    pids+=("$!")
    sequence=$((sequence + 1))
    sleep 1
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
}

start_traffic() {
  local max_seconds="$1"

  traffic_stop_file="$traffic_dir/stop"
  rm -f -- "$traffic_stop_file"
  traffic_loop "$max_seconds" &
  traffic_pid=$!
}

traffic_running() {
  [[ -n "$traffic_pid" ]] && kill -0 "$traffic_pid" 2>/dev/null
}

collect_meta_json() {
  local file
  local files=()

  shopt -s nullglob
  files=("$traffic_dir"/meta-*.json)
  if ((${#files[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  {
    for file in "${files[@]}"; do
      command cat -- "$file"
    done
  } | jq -s 'sort_by(.sequence)'
}

completed_sample_count() {
  local files=()

  shopt -s nullglob
  files=("$traffic_dir"/meta-*.json)
  printf '%s' "${#files[@]}"
}

wait_for_sample_count() {
  local expected_count="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    if (("$(completed_sample_count)" >= expected_count)); then
      return 0
    fi
    traffic_running || return 1
    sleep 1
  done
  return 1
}

wait_for_survivor_samples_after() {
  local after_ms="$1"
  local expected_count="$2"
  local timeout_seconds="$3"
  local deadline=$((SECONDS + timeout_seconds))
  local samples count

  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    samples="$(collect_meta_json)"
    count="$(
      jq --argjson after "$after_ms" --arg region "$surviving_region" '
        [.[] | select(
          .started_ms >= $after and .http_status == 200 and
          .valid == true and .region == $region
        )] | length
      ' <<<"$samples"
    )"
    ((count >= expected_count)) && return 0
    traffic_running || return 1
    sleep 1
  done
  return 1
}

wait_for_valid_samples_after() {
  local after_ms="$1"
  local expected_count="$2"
  local timeout_seconds="$3"
  local deadline=$((SECONDS + timeout_seconds))
  local samples count

  while ((SECONDS < deadline && SECONDS < global_deadline)); do
    samples="$(collect_meta_json)"
    count="$(
      jq --argjson after "$after_ms" '
        [.[] | select(
          .started_ms >= $after and .http_status == 200 and .valid == true
        )] | length
      ' <<<"$samples"
    )"
    ((count >= expected_count)) && return 0
    traffic_running || return 1
    sleep 1
  done
  return 1
}

classify_failed_requests() {
  local samples="$1"
  local fault_started="$2"
  local traffic_converged="$3"

  jq -c \
    --argjson fault_started "$fault_started" \
    --argjson traffic_converged "$traffic_converged" '
      {
        transition_failed_requests: ([.[] | select(
          .http_status != 200 and
          .completed_ms >= $fault_started and
          .started_ms < $traffic_converged
        )] | length),
        out_of_window_failed_requests: ([.[] | select(
          .http_status != 200 and
          (.completed_ms < $fault_started or
           .started_ms >= $traffic_converged)
        )] | length)
      }
    ' <<<"$samples"
}

test_failure_window_fixtures() {
  local fixture="$repo_root/testdata/failover-failure-window-fixtures.json"
  local fault_started traffic_converged case_count index
  local case_name samples expected actual

  [[ -f "$fixture" ]] || fail "failure-window fixture is missing: $fixture"
  jq -e '
    . as $root |
    (.fault_started_ms < .backend_drained_ms) and
    (.backend_drained_ms < .traffic_converged_ms) and
    any(.cases[];
      any(.samples[];
        .http_status != 200 and
        .started_ms >= $root.backend_drained_ms and
        .started_ms < $root.traffic_converged_ms
      )
    ) and
    any(.cases[];
      any(.samples[];
        .http_status != 200 and
        .started_ms == $root.traffic_converged_ms
      )
    ) and
    any(.cases[];
      any(.samples[];
        .http_status != 200 and
        .started_ms > $root.traffic_converged_ms
      )
    ) and
    any(.cases[];
      any(.samples[];
        .http_status != 200 and
        .completed_ms < $root.fault_started_ms
      )
    )
  ' "$fixture" >/dev/null \
    || fail "failure-window fixture does not cover every boundary"

  fault_started="$(jq -r '.fault_started_ms' "$fixture")"
  traffic_converged="$(jq -r '.traffic_converged_ms' "$fixture")"
  case_count="$(jq '.cases | length' "$fixture")"
  for ((index = 0; index < case_count; index++)); do
    case_name="$(jq -r --argjson index "$index" '.cases[$index].name' "$fixture")"
    samples="$(jq -c --argjson index "$index" '.cases[$index].samples' "$fixture")"
    expected="$(jq -c --argjson index "$index" '.cases[$index].expected' "$fixture")"
    actual="$(
      classify_failed_requests "$samples" "$fault_started" "$traffic_converged"
    )"
    jq -en --argjson actual "$actual" --argjson expected "$expected" \
      '$actual == $expected' >/dev/null \
      || fail "failure-window fixture failed: $case_name"
  done
}

write_evidence() {
  local samples="$1"
  local baseline_backend="$2"
  local drained_backend="$3"
  local recovered_backend="$4"
  local csv_candidate="$work_dir/09-failover.csv"
  local summary_candidate="$work_dir/10-backend-health-after.txt"
  local row request_count failed_requests failure_counts
  local transition_failed_requests out_of_window_failed_requests
  local invalid_successes survivor_after_drain
  local last_target_timestamp first_survivor_timestamp
  local cache_drain_duration lb_drain_duration traffic_convergence_duration
  local post_backend_drain_convergence_duration
  local cache_recovery_duration lb_recovery_duration
  local traffic_span_ms average_interval_ms observed_request_rate
  local row_files=()

  request_count="$(jq 'length' <<<"$samples")"
  failed_requests="$(jq '[.[] | select(.http_status != 200)] | length' <<<"$samples")"
  invalid_successes="$(
    jq '[.[] | select(.http_status == 200 and .valid != true)] | length' \
      <<<"$samples"
  )"
  ((fault_started_ms <= lb_drained_ms)) \
    && ((lb_drained_ms <= traffic_converged_ms)) \
    && ((traffic_converged_ms <= restore_started_ms)) \
    || fail "the recorded failover boundaries are not chronological"
  failure_counts="$(
    classify_failed_requests \
      "$samples" "$fault_started_ms" "$traffic_converged_ms"
  )"
  transition_failed_requests="$(
    jq -r '.transition_failed_requests' <<<"$failure_counts"
  )"
  out_of_window_failed_requests="$(
    jq -r '.out_of_window_failed_requests' <<<"$failure_counts"
  )"
  survivor_after_drain="$(
    jq --argjson drained "$lb_drained_ms" \
      --argjson restore_started "$restore_started_ms" \
      --arg region "$surviving_region" '
      [.[] | select(
        .started_ms >= $drained and .started_ms < $restore_started and
        .http_status == 200 and .valid == true and .region == $region
      )] | length
    ' <<<"$samples"
  )"
  last_target_timestamp="$(
    jq -r --argjson restore_started "$restore_started_ms" \
      --arg region "$fault_target_region" '
      [.[] | select(
        .completed_ms < $restore_started and .http_status == 200 and
        .valid == true and .region == $region
      )] | sort_by(.completed_ms) | last | .timestamp // "none"
    ' <<<"$samples"
  )"
  first_survivor_timestamp="$(
    jq -r --argjson start "$fault_started_ms" --arg region "$surviving_region" '
      [.[] | select(
        .started_ms >= $start and .http_status == 200 and
        .valid == true and .region == $region
      )] | sort_by(.completed_ms) | first | .timestamp // "none"
    ' <<<"$samples"
  )"

  ((request_count > 0)) || fail "the failover traffic run produced no requests"
  ((invalid_successes == 0)) \
    || fail "the endpoint returned $invalid_successes malformed HTTP 200 responses"
  ((out_of_window_failed_requests == 0)) \
    || fail "$out_of_window_failed_requests failed requests occurred before fault injection or at/after public traffic convergence"
  ((transition_failed_requests <= max_transition_failed_requests)) \
    || fail "the endpoint recorded $transition_failed_requests transition failures, exceeding the allowed $max_transition_failed_requests"
  ((failed_requests == transition_failed_requests + out_of_window_failed_requests)) \
    || fail "the failure-window accounting did not classify every failed request"
  ((survivor_after_drain >= survivor_sample_count)) \
    || fail "the CSV does not retain enough surviving-cell responses after drain"
  jq -e '
    ([.[].sequence] == [range(1; length + 1)]) and
    ([.[].correlation_id] | length == (unique | length)) and
    all(.[];
      (.sequence >= 1) and
      (.started_ms > 0) and (.completed_ms >= .started_ms) and
      (.latency_ms >= 0) and
      (.correlation_id | test(
        "^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"
      )))
  ' <<<"$samples" >/dev/null \
    || fail "the traffic metadata contains duplicate or malformed request evidence"

  traffic_span_ms="$(
    jq '.[-1].started_ms - .[0].started_ms' <<<"$samples"
  )"
  if ((request_count > 1 && traffic_span_ms > 0)); then
    average_interval_ms="$((traffic_span_ms / (request_count - 1)))"
    observed_request_rate="$(
      awk -v count="$request_count" -v span="$traffic_span_ms" \
        'BEGIN { printf "%.3f", (count - 1) * 1000 / span }'
    )"
  else
    average_interval_ms=0
    observed_request_rate=0
  fi
  ((average_interval_ms >= 750 && average_interval_ms <= 1500)) \
    || fail "the observed traffic interval was not approximately one second"

  printf '%s\n' \
    'timestamp,http_status,latency_ms,serving_region,serving_cluster,correlation_id' \
    >"$csv_candidate"
  shopt -s nullglob
  row_files=("$traffic_dir"/row-*.csv)
  for row in "${row_files[@]}"; do
    command cat -- "$row" >>"$csv_candidate"
  done
  [[ "$(( $(wc -l <"$csv_candidate") - 1 ))" == "$request_count" ]] \
    || fail "the CSV row count does not match the completed traffic metadata"
  awk -F, '
    NR == 1 {
      if ($0 != "timestamp,http_status,latency_ms,serving_region,serving_cluster,correlation_id") exit 1
      next
    }
    NF != 6 || $2 !~ /^[0-9][0-9][0-9]$/ || $3 !~ /^[0-9]+$/ { exit 1 }
  ' "$csv_candidate" || fail "the failover CSV does not match its frozen schema"

  cache_drain_duration="$((cache_unhealthy_ms - fault_started_ms))"
  lb_drain_duration="$((lb_drained_ms - fault_started_ms))"
  traffic_convergence_duration="$((traffic_converged_ms - fault_started_ms))"
  post_backend_drain_convergence_duration="$((
    traffic_converged_ms - lb_drained_ms
  ))"
  cache_recovery_duration="$((cache_recovered_ms - restore_started_ms))"
  lb_recovery_duration="$((lb_recovered_ms - restore_started_ms))"

  {
    printf 'Failover gate: PASS\n'
    if [[ "$app_a_sha" == "$app_b_sha" ]]; then
      printf 'image_sha=%s\n' "$app_a_sha"
    else
      printf 'image_sha=mixed\n'
    fi
    printf 'app_a_image_sha=%s\n' "$app_a_sha"
    printf 'app_b_image_sha=%s\n' "$app_b_sha"
    printf 'fault_target=%s (%s)\n' "$fault_target_region" "$fault_target_context"
    printf 'surviving_cell=%s (%s)\n' "$surviving_region" "$surviving_context"
    printf 'configured_traffic_rate=1 request/second\n'
    printf 'observed_request_rate_per_second=%s\n' "$observed_request_rate"
    printf 'observed_average_interval_ms=%s\n' "$average_interval_ms"
    printf 'requests=%s\n' "$request_count"
    printf 'failed_requests=%s\n' "$failed_requests"
    printf 'maximum_allowed_transition_failures=%s\n' \
      "$max_transition_failed_requests"
    printf 'transition_failed_requests=%s\n' "$transition_failed_requests"
    printf 'failed_requests_outside_transition_window=%s\n' \
      "$out_of_window_failed_requests"
    printf 'cache_drain_seconds=%s\n' \
      "$(milliseconds_as_seconds "$cache_drain_duration")"
    printf 'load_balancer_drain_seconds=%s\n' \
      "$(milliseconds_as_seconds "$lb_drain_duration")"
    printf 'public_traffic_convergence_seconds=%s\n' \
      "$(milliseconds_as_seconds "$traffic_convergence_duration")"
    printf 'post_backend_drain_convergence_seconds=%s\n' \
      "$(milliseconds_as_seconds "$post_backend_drain_convergence_duration")"
    printf 'cache_recovery_seconds=%s\n' \
      "$(milliseconds_as_seconds "$cache_recovery_duration")"
    printf 'load_balancer_recovery_seconds=%s\n' \
      "$(milliseconds_as_seconds "$lb_recovery_duration")"
    printf 'last_successful_target_request=%s\n' "$last_target_timestamp"
    printf 'first_successful_survivor_request=%s\n' "$first_survivor_timestamp"
    printf 'survivor_successes_after_drain=%s\n' "$survivor_after_drain"
    printf 'backend_health_before=%s\n' \
      "$(compact_backend_summary "$baseline_backend")"
    printf 'backend_health_during=%s\n' \
      "$(compact_backend_summary "$drained_backend")"
    printf 'backend_health_after=%s\n' \
      "$(compact_backend_summary "$recovered_backend")"
    printf 'both_cells_healthy_after=true\n'
  } >"$summary_candidate"

  mv -f -- "$csv_candidate" "$evidence_dir/09-failover.csv"
  mv -f -- "$summary_candidate" "$evidence_dir/10-backend-health-after.txt"
}

main() {
  local active_account configured_project configured_impersonation contexts
  local lb_outputs baseline_samples baseline_window baseline_latest
  local baseline_backend drained_backend recovered_backend
  local traffic_max_seconds

  if [[ $# -eq 1 && "$1" == "--test-failure-window" ]]; then
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    test_failure_window_fixtures
    printf 'Failover failure-window fixtures: PASS\n'
    return 0
  fi
  if [[ $# -ne 2 ]]; then
    printf 'Usage: %s FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA | --test-failure-window\n' "$0" >&2
    exit 2
  fi

  : "${PROJECT_ID:?PROJECT_ID is required}"
  : "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

  app_a_sha="$1"
  app_b_sha="$2"
  test_timeout_seconds="${FAILOVER_TEST_TIMEOUT_SECONDS:-900}"
  baseline_sample_count="${FAILOVER_BASELINE_SAMPLES:-5}"
  survivor_sample_count="${FAILOVER_SURVIVOR_SAMPLES:-5}"
  post_recovery_sample_count="${FAILOVER_POST_RECOVERY_SAMPLES:-3}"
  # The 60-request ceiling is a test guard, not a promised production RTO.
  # It covers the frozen 30-second connection-draining window plus readiness
  # and external health-check detection while still rejecting a long outage.
  max_transition_failed_requests="${FAILOVER_MAX_TRANSITION_FAILURES:-60}"
  fault_activation_timeout_seconds="${FAULT_ACTIVATION_TIMEOUT_SECONDS:-180}"
  cache_timeout_seconds="${CELL_DRAIN_TIMEOUT_SECONDS:-120}"
  backend_timeout_seconds="${LB_TRANSITION_TIMEOUT_SECONDS:-240}"
  recovery_timeout_seconds="${FAILOVER_RECOVERY_TIMEOUT_SECONDS:-300}"

  [[ "$PROJECT_ID" == "$expected_project" ]] \
    || fail "expected project $expected_project, received $PROJECT_ID"
  [[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
    || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"
  [[ "$app_a_sha" =~ ^[0-9a-f]{40}$ ]] \
    || fail "the App A image version must be one full lowercase 40-character Git SHA"
  [[ "$app_b_sha" =~ ^[0-9a-f]{40}$ ]] \
    || fail "the App B image version must be one full lowercase 40-character Git SHA"

  [[ "$test_timeout_seconds" =~ ^[0-9]+$ ]] \
    && ((test_timeout_seconds >= 300 && test_timeout_seconds <= 1800)) \
    || fail "FAILOVER_TEST_TIMEOUT_SECONDS must be between 300 and 1800"
  [[ "$baseline_sample_count" =~ ^[0-9]+$ ]] \
    && ((baseline_sample_count >= 3 && baseline_sample_count <= 30)) \
    || fail "FAILOVER_BASELINE_SAMPLES must be between 3 and 30"
  [[ "$survivor_sample_count" =~ ^[0-9]+$ ]] \
    && ((survivor_sample_count >= 3 && survivor_sample_count <= 30)) \
    || fail "FAILOVER_SURVIVOR_SAMPLES must be between 3 and 30"
  [[ "$post_recovery_sample_count" =~ ^[0-9]+$ ]] \
    && ((post_recovery_sample_count >= 2 && post_recovery_sample_count <= 30)) \
    || fail "FAILOVER_POST_RECOVERY_SAMPLES must be between 2 and 30"
  [[ "$max_transition_failed_requests" =~ ^[0-9]+$ ]] \
    && ((max_transition_failed_requests <= 60)) \
    || fail "FAILOVER_MAX_TRANSITION_FAILURES must be between 0 and 60"
  for value in \
    "$fault_activation_timeout_seconds" "$cache_timeout_seconds" \
    "$backend_timeout_seconds" "$recovery_timeout_seconds"; do
    [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 60 && value <= 600)) \
      || fail "each failover phase timeout must be between 60 and 600 seconds"
  done

  for command_name in awk curl date gcloud git jq kubectl od sed sha256sum sort terraform timeout wc; do
    command -v "$command_name" >/dev/null 2>&1 \
      || fail "$command_name is required"
  done
  for override_name in \
    CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
    CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
    CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
    GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
    [[ -z "${!override_name:-}" ]] \
      || fail "$override_name must be unset so the named gcloud account is authoritative"
  done
  for required_file in \
    "$repo_root/testdata/expected-exchange-rates.json" \
    "$repo_root/testdata/failover-failure-window-fixtures.json" \
    "$repo_root/k8s/faults/healthy.yaml" \
    "$repo_root/k8s/faults/unavailable.yaml"; do
    [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
  done
  git cat-file -e "$app_a_sha^{commit}" 2>/dev/null \
    || fail "App A Git SHA $app_a_sha is not a commit in this repository"
  git cat-file -e "$app_b_sha^{commit}" 2>/dev/null \
    || fail "App B Git SHA $app_b_sha is not a commit in this repository"
  test_failure_window_fixtures

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
    configured_impersonation="$(
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
        config get-value "$auth_property" 2>/dev/null || true
    )"
    [[ -z "$configured_impersonation" || "$configured_impersonation" == "(unset)" ]] \
      || fail "$auth_property must be unset in the named gcloud configuration"
  done

  export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
  export CLOUDSDK_CORE_ACCOUNT="$expected_account"
  export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
  export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
  bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

  mkdir -p "$runtime_dir" "$evidence_dir"
  git check-ignore --quiet -- "$runtime_dir/failover-kubeconfig-check" \
    || fail "the repo-local failover runtime path must stay ignored by Git"
  # A failed rerun must not leave an older PASS eligible as current evidence.
  rm -f -- "$evidence_dir/09-failover.csv" \
    "$evidence_dir/10-backend-health-after.txt"
  work_dir="$(mktemp -d "$runtime_dir/test-failover.XXXXXX")"
  traffic_dir="$work_dir/traffic"
  mkdir -p "$traffic_dir"
  prepare_kubeconfig
  contexts="$(kubectl config get-contexts -o name | tr -d '\r' | sort)"
  [[ "$contexts" == $'gke-risk-usc1\ngke-risk-use4' ]] \
    || fail "the failover kubeconfig lost its exact isolated contexts"
  validate_fault_manifest "$repo_root/k8s/faults/healthy.yaml" \
    682b2465d516834966d35f242c68442c22685c602f126ec50c4cc04b438a092f \
    || fail "the checked-in healthy fault manifest is not exact"
  validate_fault_manifest "$repo_root/k8s/faults/unavailable.yaml" \
    b209b6d6ac923afb623869f65281c668da8aef51743a8186d4bec6040eec2153 \
    || fail "the checked-in unavailable fault manifest is not exact"

  global_deadline=$((SECONDS + test_timeout_seconds))
  validate_cell_resources gke-risk-usc1 \
    || fail "us-central1 baseline resources are not healthy and immutable"
  validate_cell_resources gke-risk-use4 \
    || fail "us-east4 baseline resources are not healthy and immutable"
  wait_for_all_app_b_pods_ready gke-risk-usc1 120 \
    || fail "us-central1 App B baseline Pods are not ready"
  wait_for_all_app_b_pods_ready gke-risk-use4 120 \
    || fail "us-east4 App B baseline Pods are not ready"
  wait_for_all_app_a_pods_state gke-risk-usc1 200 HEALTHY 120 \
    || fail "us-central1 App A Pods do not all report cached cell health"
  wait_for_all_app_a_pods_state gke-risk-use4 200 HEALTHY 120 \
    || fail "us-east4 App A Pods do not all report cached cell health"
  wait_for_backend_state healthy "$backend_timeout_seconds" \
    || fail "all six zonal backends must be healthy before fault injection"
  baseline_backend="$backend_summary"

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
    ((.neg_backends.value | length) == 6) and
    ($endpoint | test("^https://[A-Za-z0-9.-]+$"))
  ' <<<"$lb_outputs" >/dev/null \
    || fail "the Terraform outputs do not describe the frozen HTTPS-only public edge"

  traffic_max_seconds=$((test_timeout_seconds + 15))
  start_traffic "$traffic_max_seconds"
  wait_for_sample_count "$baseline_sample_count" 60 \
    || fail "the one-request-per-second recorder did not produce its baseline"
  baseline_samples="$(collect_meta_json)"
  baseline_window="$(
    jq --argjson count "$baseline_sample_count" '.[0:$count]' \
      <<<"$baseline_samples"
  )"
  jq -e --argjson count "$baseline_sample_count" '
    (length == $count) and
    all(.[]; .http_status == 200 and .valid == true)
  ' <<<"$baseline_window" >/dev/null \
    || fail "the global endpoint baseline contains a failed or invalid response"
  baseline_latest="$(jq -c 'last' <<<"$baseline_window")"
  fault_target_region="$(jq -r '.region' <<<"$baseline_latest")"
  case "$fault_target_region" in
    us-central1)
      fault_target_context=gke-risk-usc1
      surviving_region=us-east4
      surviving_context=gke-risk-use4
      ;;
    us-east4)
      fault_target_context=gke-risk-use4
      surviving_region=us-central1
      surviving_context=gke-risk-usc1
      ;;
    *) fail "the live endpoint did not identify one of the two real cells" ;;
  esac
  printf 'Live traffic selected %s; faulting only explicit context %s.\n' \
    "$fault_target_region" "$fault_target_context"

  restore_required=1
  fault_started_ms="$(now_epoch_ms)"
  apply_fault_profile "$fault_target_context" unavailable 1.0 \
    || fail "$fault_target_context did not accept the unavailable profile"
  wait_for_all_app_b_pods_ready "$fault_target_context" \
    "$fault_activation_timeout_seconds" \
    || fail "target App B Pods did not remain ready during the injected fault"
  wait_for_all_app_a_pods_state "$fault_target_context" 503 UNHEALTHY \
    "$cache_timeout_seconds" \
    || fail "target App A readiness stayed up, but cached cell health did not drain in time"
  cache_unhealthy_ms="$(now_epoch_ms)"
  wait_for_backend_state target-drained "$backend_timeout_seconds" \
    || fail "the load balancer did not remove all target-region endpoints"
  # This is the backend health/control-plane boundary, not proof that public
  # traffic has already converged on the surviving cell.
  lb_drained_ms="$(now_epoch_ms)"
  drained_backend="$backend_summary"

  wait_for_all_app_a_pods_state "$surviving_context" 200 HEALTHY 120 \
    || fail "the surviving cell did not remain independently healthy"
  wait_for_survivor_samples_after "$lb_drained_ms" "$survivor_sample_count" 120 \
    || fail "global traffic did not prove the surviving region after target drain"
  traffic_converged_ms="$(now_epoch_ms)"

  restore_started_ms="$(now_epoch_ms)"
  apply_fault_profile "$fault_target_context" healthy 0.0 \
    || fail "$fault_target_context did not accept the healthy profile"
  wait_for_all_app_b_pods_ready "$fault_target_context" \
    "$recovery_timeout_seconds" \
    || fail "target App B Pods were not ready during recovery"
  wait_for_all_app_a_pods_state "$fault_target_context" 200 HEALTHY \
    "$recovery_timeout_seconds" \
    || fail "target App A cached cell health did not recover"
  cache_recovered_ms="$(now_epoch_ms)"
  wait_for_backend_state healthy "$backend_timeout_seconds" \
    || fail "all six zonal backends did not recover"
  lb_recovered_ms="$(now_epoch_ms)"
  recovered_backend="$backend_summary"

  # Re-run both-cell checks after restoration instead of assuming recovery from
  # the ConfigMap or backend state alone.
  validate_cell_resources gke-risk-usc1 \
    || fail "us-central1 failed the post-fault immutable workload check"
  validate_cell_resources gke-risk-use4 \
    || fail "us-east4 failed the post-fault immutable workload check"
  wait_for_all_app_b_pods_ready gke-risk-usc1 120 \
    || fail "us-central1 App B failed the post-fault readiness check"
  wait_for_all_app_b_pods_ready gke-risk-use4 120 \
    || fail "us-east4 App B failed the post-fault readiness check"
  wait_for_all_app_a_pods_state gke-risk-usc1 200 HEALTHY 120 \
    || fail "us-central1 failed the post-fault cached cell-health check"
  wait_for_all_app_a_pods_state gke-risk-use4 200 HEALTHY 120 \
    || fail "us-east4 failed the post-fault cached cell-health check"
  wait_for_backend_state healthy 120 \
    || fail "backend health regressed during the post-fault checks"
  recovered_backend="$backend_summary"

  wait_for_valid_samples_after "$lb_recovered_ms" \
    "$post_recovery_sample_count" 60 \
    || fail "the global endpoint did not remain healthy after recovery"
  restore_required=0
  stop_traffic

  final_samples="$(collect_meta_json)"
  write_evidence "$final_samples" \
    "$baseline_backend" "$drained_backend" "$recovered_backend"
  command cat -- "$evidence_dir/10-backend-health-after.txt"
  printf 'Evidence: evidence/09-failover.csv and evidence/10-backend-health-after.txt\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  main "$@"
fi

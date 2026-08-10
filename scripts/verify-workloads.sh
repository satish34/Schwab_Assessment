#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
auth_audience="https://app-b-engine.schwab-assessment.internal"
namespace="risk-system"
runtime_dir="$repo_root/.tmp"
kubeconfig="$runtime_dir/kubeconfig-schwab-assessment"
kubeconfig_candidate=""
work_dir=""
active_port_forward_pid=""
workload_timeout_seconds="${WORKLOAD_TIMEOUT_SECONDS:-900}"
cell_timeout_seconds="${CELL_VERIFY_TIMEOUT_SECONDS:-90}"

fail() {
  printf 'verify-workloads: %s\n' "$*" >&2
  exit 1
}

stop_port_forward() {
  if [[ -n "$active_port_forward_pid" ]]; then
    kill "$active_port_forward_pid" 2>/dev/null || true
    wait "$active_port_forward_pid" 2>/dev/null || true
    active_port_forward_pid=""
  fi
}

cleanup() {
  local exit_code=$?

  stop_port_forward
  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/verify-workloads.*)
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

git_sha="$1"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project, received $PROJECT_ID"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "the image version must be one full lowercase 40-character Git SHA"
[[ "$workload_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((workload_timeout_seconds >= 30 && workload_timeout_seconds <= 3600)) \
  || fail "WORKLOAD_TIMEOUT_SECONDS must be between 30 and 3600"
[[ "$cell_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((cell_timeout_seconds >= 15 && cell_timeout_seconds <= 300)) \
  || fail "CELL_VERIFY_TIMEOUT_SECONDS must be between 15 and 300"

for command_name in curl gcloud git jq kubectl od terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done

git cat-file -e "$git_sha^{commit}" 2>/dev/null \
  || fail "Git SHA $git_sha is not a commit in this repository"
[[ -f "$repo_root/testdata/expected-exchange-rates.json" ]] \
  || fail "the expected exchange-rate response fixture is missing"

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

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

# Recheck the immutable registry contract on every standalone verification run.
timeout --foreground --signal=INT 5m bash scripts/verify-images.sh "$git_sha"

mkdir -p "$runtime_dir"
git check-ignore --quiet -- "$kubeconfig" \
  || fail "the repo-local kubeconfig path is not ignored by Git"

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

  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    container clusters get-credentials "$cluster" \
    --region="$region"

  source_context="$(kubectl config current-context | tr -d '\r')"
  [[ -n "$source_context" ]] \
    || fail "gcloud did not create a context for $cluster"
  if [[ "$source_context" != "$context" ]]; then
    kubectl config rename-context "$source_context" "$context" >/dev/null
  fi
}

prepare_kubeconfig() {
  local contexts

  kubeconfig_candidate="$(mktemp "$runtime_dir/kubeconfig.new.XXXXXX")"
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

  mv -f -- "$kubeconfig_candidate" "$kubeconfig"
  kubeconfig_candidate=""
  chmod 600 "$kubeconfig" 2>/dev/null || true
  set_kubeconfig "$kubeconfig"

  MSYS_NO_PATHCONV=1 kubectl --context=gke-risk-usc1 \
    --request-timeout=15s get --raw=/version >/dev/null
  MSYS_NO_PATHCONV=1 kubectl --context=gke-risk-use4 \
    --request-timeout=15s get --raw=/version >/dev/null
}

print_diagnostics() {
  local context="$1"

  printf '\nWorkload diagnostics for %s:\n' "$context" >&2
  kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
    get deployments,replicasets,pods,services,hpa,pdb -o wide >&2 || true
  printf '\nRecent namespace events for %s:\n' "$context" >&2
  kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
    get events --sort-by=.lastTimestamp 2>&1 | tail -n 40 >&2 || true
}

workload_ready() {
  local context="$1"
  local deployment="$2"
  local image="$3"
  local min_replicas="$4"
  local max_replicas="$5"
  local deployment_json
  local hpa_json
  local pods_json
  local replicas

  deployment_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get deployment "$deployment" -o json 2>/dev/null
  )" || return 1
  pods_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get pods --selector="app=$deployment" -o json 2>/dev/null
  )" || return 1
  hpa_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get horizontalpodautoscaler "$deployment" -o json 2>/dev/null
  )" || return 1

  jq -e \
    --arg image "$image" \
    --arg auth_audience "$auth_audience" \
    --arg caller_email "currency-app-a-caller@$PROJECT_ID.iam.gserviceaccount.com" \
    --arg project_id "$PROJECT_ID" \
    --argjson min "$min_replicas" \
    --argjson max "$max_replicas" '
    def literal_env($name; $value):
      [.spec.template.spec.containers[0].env[]?
        | select(.name == $name and .value == $value)] | length == 1;
    (.spec.replicas // 0) as $replicas |
    (.metadata.generation <= (.status.observedGeneration // 0)) and
    ($replicas >= $min and $replicas <= $max) and
    (.status.replicas == $replicas) and
    (.status.updatedReplicas == $replicas) and
    (.status.readyReplicas == $replicas) and
    (.status.availableReplicas == $replicas) and
    ((.status.unavailableReplicas // 0) == 0) and
    ([.spec.template.spec.containers[].image] == [$image]) and
    (.spec.template.spec.serviceAccountName == "app-b-engine") and
    (.spec.template.spec.automountServiceAccountToken == false) and
    literal_env("APP_B_AUTH_MODE"; "google-id-token") and
    literal_env("APP_B_TOKEN_AUDIENCE"; $auth_audience) and
    literal_env("APP_A_IDENTITY_EMAIL"; $caller_email) and
    literal_env("GOOGLE_CLOUD_PROJECT"; $project_id)
  ' <<<"$deployment_json" >/dev/null || return 1

  replicas="$(jq -r '.spec.replicas' <<<"$deployment_json" | tr -d '\r')"
  jq -e --argjson replicas "$replicas" \
    --argjson min "$min_replicas" --argjson max "$max_replicas" '
    any(.status.conditions[]?; .type == "AbleToScale" and .status == "True") and
    any(.status.conditions[]?; .type == "ScalingActive" and .status == "True") and
    (.spec.scaleTargetRef == {
      "apiVersion":"apps/v1",
      "kind":"Deployment",
      "name":.metadata.name
    }) and
    (.spec.minReplicas == $min) and
    (.spec.maxReplicas == $max) and
    (.spec.metrics == [{
      "type":"Resource",
      "resource":{
        "name":"cpu",
        "target":{"type":"Utilization","averageUtilization":70}
      }
    }]) and
    (.status.currentReplicas == $replicas) and
    (.status.desiredReplicas == $replicas)
  ' <<<"$hpa_json" >/dev/null || return 1

  jq -e --arg image "$image" --argjson replicas "$replicas" '
    (.items | length) == $replicas and
    all(.items[];
      (.metadata.deletionTimestamp == null) and
      (.status.phase == "Running") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      ([.spec.containers[].image] == [$image]) and
      ([.status.containerStatuses[]?.image] == [$image]) and
      all(.status.containerStatuses[]?; .ready == true)
    )
  ' <<<"$pods_json" >/dev/null
}

app_a_shards_ready() {
  local context="$1"
  local image="$2"
  local zone_a="$3"
  local zone_b="$4"
  local zone_c="$5"
  local deployments_json
  local hpas_json
  local pods_json
  local deployment_name
  local replicas
  local shard
  local expected_zone
  local node_name
  local actual_zone

  deployments_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get deployments --selector='app=app-a-gateway' -o json 2>/dev/null
  )" || return 1
  pods_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get pods --selector='app=app-a-gateway' -o json 2>/dev/null
  )" || return 1
  hpas_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get horizontalpodautoscalers \
        app-a-gateway-a app-a-gateway-b app-a-gateway-c -o json 2>/dev/null
  )" || return 1

  jq -e \
    --arg image "$image" \
    --arg auth_audience "$auth_audience" \
    --arg project_id "$PROJECT_ID" \
    --arg zone_a "$zone_a" \
    --arg zone_b "$zone_b" \
    --arg zone_c "$zone_c" \
    '
      def literal_env($name; $value):
        [.spec.template.spec.containers[0].env[]?
          | select(.name == $name and .value == $value)] | length == 1;
      def expected_shard($name):
        if $name == "app-a-gateway-a" then "a"
        elif $name == "app-a-gateway-b" then "b"
        elif $name == "app-a-gateway-c" then "c"
        else ""
        end;
      def expected_zone($shard):
        if $shard == "a" then $zone_a
        elif $shard == "b" then $zone_b
        elif $shard == "c" then $zone_c
        else ""
        end;
      ([.items[].metadata.name] | sort) == [
        "app-a-gateway-a",
        "app-a-gateway-b",
        "app-a-gateway-c"
      ] and
      (([.items[].status.readyReplicas] | add) >= 3) and
      (([.items[].status.readyReplicas] | add) <= 6) and
      all(.items[];
        expected_shard(.metadata.name) as $shard |
        (.spec.replicas // 0) as $replicas |
        (.metadata.generation <= (.status.observedGeneration // 0)) and
        ($replicas >= 1 and $replicas <= 2) and
        (.metadata.labels["app-a-shard"] == $shard) and
        (.spec.selector.matchLabels == {
          "app":"app-a-gateway", "app-a-shard":$shard
        }) and
        (.spec.template.metadata.labels["app-a-shard"] == $shard) and
        (.status.replicas == $replicas) and
        (.status.updatedReplicas == $replicas) and
        (.status.readyReplicas == $replicas) and
        (.status.availableReplicas == $replicas) and
        ((.status.unavailableReplicas // 0) == 0) and
        (.spec.template.spec.serviceAccountName == "app-a-gateway") and
        (.spec.template.spec.automountServiceAccountToken == false) and
        literal_env("APP_B_AUTH_MODE"; "google-id-token") and
        literal_env("APP_B_TOKEN_AUDIENCE"; $auth_audience) and
        literal_env("GOOGLE_CLOUD_PROJECT"; $project_id) and
        (.spec.template.spec.nodeSelector["topology.kubernetes.io/zone"]
          == expected_zone($shard)) and
        ([.spec.template.spec.containers[].image] == [$image])
      )
    ' <<<"$deployments_json" >/dev/null || return 1

  jq -e '
      def expected_shard($name):
        if $name == "app-a-gateway-a" then "a"
        elif $name == "app-a-gateway-b" then "b"
        elif $name == "app-a-gateway-c" then "c"
        else ""
        end;
      def reconciled_hpa:
        any(.status.conditions[]?; .type == "AbleToScale" and .status == "True") and
        any(.status.conditions[]?; .type == "ScalingActive" and .status == "True");
      ([.items[].metadata.name] | sort) == [
        "app-a-gateway-a",
        "app-a-gateway-b",
        "app-a-gateway-c"
      ] and
      all(.items[];
        expected_shard(.metadata.name) as $shard |
        reconciled_hpa and
        (.metadata.labels["app-a-shard"] == $shard) and
        (.spec.scaleTargetRef == {
          "apiVersion":"apps/v1",
          "kind":"Deployment",
          "name":.metadata.name
        }) and
        (.spec.minReplicas == 1) and
        (.spec.maxReplicas == 2) and
        (.spec.metrics == [{
          "type":"Resource",
          "resource":{
            "name":"cpu",
            "target":{"type":"Utilization","averageUtilization":70}
          }
        }]) and
        (.status.currentReplicas >= 1 and .status.currentReplicas <= 2) and
        (.status.desiredReplicas == .status.currentReplicas)
      )
    ' <<<"$hpas_json" >/dev/null || return 1

  for shard in a b c; do
    deployment_name="app-a-gateway-$shard"
    replicas="$(
      jq -r --arg name "$deployment_name" \
        '.items[] | select(.metadata.name == $name) | .spec.replicas' \
        <<<"$deployments_json" | tr -d '\r'
    )"
    jq -e --arg name "$deployment_name" --argjson replicas "$replicas" '
      [.items[] | select(
        .metadata.name == $name and
        .status.currentReplicas == $replicas and
        .status.desiredReplicas == $replicas
      )] | length == 1
    ' <<<"$hpas_json" >/dev/null || return 1
  done

  jq -e \
    --arg image "$image" \
    --arg zone_a "$zone_a" \
    --arg zone_b "$zone_b" \
    --arg zone_c "$zone_c" \
    '
      def expected_zone($shard):
        if $shard == "a" then $zone_a
        elif $shard == "b" then $zone_b
        elif $shard == "c" then $zone_c
        else ""
        end;
      def shard_count($shard):
        [.items[] | select(.metadata.labels["app-a-shard"] == $shard)] | length;
      ((.items | length) >= 3 and (.items | length) <= 6) and
      (shard_count("a") >= 1 and shard_count("a") <= 2) and
      (shard_count("b") >= 1 and shard_count("b") <= 2) and
      (shard_count("c") >= 1 and shard_count("c") <= 2) and
      all(.items[];
        (.metadata.deletionTimestamp == null) and
        (.status.phase == "Running") and
        any(.status.conditions[]?; .type == "Ready" and .status == "True") and
        ([.spec.containers[].image] == [$image]) and
        ([.status.containerStatuses[]?.image] == [$image]) and
        all(.status.containerStatuses[]?; .ready == true) and
        (.spec.nodeSelector["topology.kubernetes.io/zone"]
          == expected_zone(.metadata.labels["app-a-shard"])) and
        ((.spec.nodeName // "") | length > 0) and
        ((.status.podIP // "") | length > 0)
      )
    ' <<<"$pods_json" >/dev/null || return 1

  for shard in a b c; do
    case "$shard" in
      a) expected_zone="$zone_a" ;;
      b) expected_zone="$zone_b" ;;
      c) expected_zone="$zone_c" ;;
    esac

    while IFS= read -r node_name; do
      [[ -n "$node_name" ]] || return 1
      actual_zone="$(
        kubectl --context="$context" --request-timeout=20s get node "$node_name" \
          -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null
      )" || return 1
      [[ "$actual_zone" == "$expected_zone" ]] || return 1
    done < <(
      jq -r --arg shard "$shard" '
        .items[]
        | select(.metadata.labels["app-a-shard"] == $shard)
        | .spec.nodeName
      ' <<<"$pods_json" | tr -d '\r'
    )
  done
}

wait_for_workloads() {
  local context="$1"
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$git_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$git_sha"
  local zone_a
  local zone_b
  local zone_c
  local deadline=$((SECONDS + workload_timeout_seconds))

  case "$context" in
    gke-risk-usc1)
      zone_a=us-central1-a
      zone_b=us-central1-b
      zone_c=us-central1-c
      ;;
    gke-risk-use4)
      zone_a=us-east4-a
      zone_b=us-east4-b
      zone_c=us-east4-c
      ;;
    *) fail "unexpected workload context $context" ;;
  esac

  while ((SECONDS < deadline)); do
    if app_a_shards_ready "$context" "$app_a_image" "$zone_a" "$zone_b" "$zone_c" \
      && workload_ready "$context" app-b-engine "$app_b_image" 2 6; then
      printf '%s has 3-6 ready App A and 2-6 ready App B Pods.\n' "$context"
      return 0
    fi
    sleep 5
  done

  print_diagnostics "$context"
  fail "$context workloads did not reach the reconciled autoscaling state within ${workload_timeout_seconds}s"
}

verify_services() {
  local context="$1"
  local expected_neg="$2"
  local app_a_json
  local app_b_json

  app_a_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get service app-a-gateway -o json
  )"
  app_b_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get service app-b-engine -o json
  )"

  jq -e --arg neg "$expected_neg" '
    (.spec.type == "ClusterIP") and
    (.spec.ports == [{"name":"http","port":8080,"protocol":"TCP","targetPort":"http"}]) and
    ((.metadata.annotations["cloud.google.com/neg"] | fromjson)
      == {"exposed_ports":{"8080":{"name":$neg}}})
  ' <<<"$app_a_json" >/dev/null \
    || fail "$context App A Service does not match its private custom-NEG contract"

  jq -e '
    (.spec.type == "ClusterIP") and
    (.spec.ports == [{"name":"http","port":8080,"protocol":"TCP","targetPort":"http"}]) and
    ((.metadata.annotations["cloud.google.com/neg"] // "{}" | fromjson) == {"ingress":false}) and
    ((.spec.externalIPs // []) | length == 0)
  ' <<<"$app_b_json" >/dev/null \
    || fail "$context App B Service is exposed or carries an unexpected NEG annotation"
}

verify_service_accounts() {
  local context="$1"
  local caller_email="currency-app-a-caller@$PROJECT_ID.iam.gserviceaccount.com"
  local app_a_json
  local app_b_json

  app_a_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get serviceaccount app-a-gateway -o json
  )"
  app_b_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get serviceaccount app-b-engine -o json
  )"

  jq -e --arg caller "$caller_email" '
    (.automountServiceAccountToken == false) and
    (.metadata.annotations["iam.gke.io/gcp-service-account"] == $caller)
  ' <<<"$app_a_json" >/dev/null \
    || fail "$context App A Kubernetes service account is not bound to the exact caller identity"
  jq -e '
    (.automountServiceAccountToken == false) and
    ((.metadata.annotations["iam.gke.io/gcp-service-account"] // "") == "")
  ' <<<"$app_b_json" >/dev/null \
    || fail "$context App B Kubernetes service account must remain unmapped"
}

random_hex() {
  local bytes="$1"
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

verify_app_b_rejects_unauthenticated_callers() {
  local context="$1"
  local port_forward_log="$work_dir/app-b-port-forward-$context.log"
  local headers="$work_dir/app-b-unauthorized-$context.headers"
  local body="$work_dir/app-b-unauthorized-$context.body"
  local deadline
  local local_port=""
  local health_status
  local status

  : >"$port_forward_log"
  kubectl --context="$context" --namespace="$namespace" \
    port-forward --address=127.0.0.1 service/app-b-engine :8080 \
    >"$port_forward_log" 2>&1 &
  active_port_forward_pid=$!

  deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    local_port="$(
      tr -d '\r' <"$port_forward_log" \
        | sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) -> 8080$/\1/p' \
        | head -n 1
    )"
    [[ -n "$local_port" ]] && break
    if ! kill -0 "$active_port_forward_pid" 2>/dev/null; then
      cat "$port_forward_log" >&2
      fail "$context App B port-forward exited before it became ready"
    fi
    sleep 1
  done
  [[ -n "$local_port" ]] || fail "$context App B port-forward did not become ready within 30s"

  health_status="$(
    curl --silent --show-error --max-time 5 \
      --output /dev/null --write-out '%{http_code}' \
      "http://127.0.0.1:$local_port/health/ready"
  )"
  [[ "$health_status" == "200" ]] \
    || fail "$context App B authenticated deployment did not keep health checks public"

  status="$(
    curl --silent --show-error --max-time 5 \
      --dump-header "$headers" --output "$body" --write-out '%{http_code}' \
      "http://127.0.0.1:$local_port/internal/exchange-rates"
  )"
  [[ "$status" == "401" ]] \
    || fail "$context App B accepted an internal request without a service token"
  [[ ! -s "$body" ]] \
    || fail "$context App B authentication rejection exposed a response body"
  grep -Eiq '^cache-control:[[:space:]]*no-store\r?$' "$headers" \
    || fail "$context App B authentication rejection did not disable caching"
  grep -Eiq '^www-authenticate:[[:space:]]*Bearer\r?$' "$headers" \
    || fail "$context App B authentication rejection omitted the Bearer challenge"

  stop_port_forward
  printf '%s App B rejected an unauthenticated call while health remained available.\n' "$context"
}

verify_local_path() {
  local context="$1"
  local expected_region="$2"
  local expected_cluster="$3"
  local port_forward_log="$work_dir/port-forward-$context.log"
  local cell_response="$work_dir/cell-$context.json"
  local response="$work_dir/response-$context.json"
  local deadline
  local local_port=""
  local status=""
  local random_raw
  local correlation_id
  local trace_id
  local span_id

  : >"$port_forward_log"
  kubectl --context="$context" --namespace="$namespace" \
    port-forward --address=127.0.0.1 service/app-a-gateway :8080 \
    >"$port_forward_log" 2>&1 &
  active_port_forward_pid=$!

  deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    local_port="$(
      tr -d '\r' <"$port_forward_log" \
        | sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) -> 8080$/\1/p' \
        | head -n 1
    )"
    [[ -n "$local_port" ]] && break
    if ! kill -0 "$active_port_forward_pid" 2>/dev/null; then
      cat "$port_forward_log" >&2
      fail "$context port-forward exited before it became ready"
    fi
    sleep 1
  done
  if [[ -z "$local_port" ]]; then
    cat "$port_forward_log" >&2
    fail "$context port-forward did not become ready within 30s"
  fi

  deadline=$((SECONDS + cell_timeout_seconds))
  while ((SECONDS < deadline)); do
    status="$(
      curl --silent --show-error --max-time 5 \
        --output "$cell_response" --write-out '%{http_code}' \
        "http://127.0.0.1:$local_port/health/cell" 2>/dev/null || true
    )"
    if [[ "$status" == "200" ]] \
      && jq -e '.status == "HEALTHY"' "$cell_response" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  [[ "$status" == "200" ]] \
    && jq -e '.status == "HEALTHY"' "$cell_response" >/dev/null 2>&1 \
    || {
      print_diagnostics "$context"
      fail "$context cell health did not become HEALTHY within ${cell_timeout_seconds}s"
    }

  random_raw="$(random_hex 16)"
  correlation_id="${random_raw:0:8}-${random_raw:8:4}-${random_raw:12:4}-${random_raw:16:4}-${random_raw:20:12}"
  trace_id="$(random_hex 16)"
  span_id="$(random_hex 8)"
  status="$(
    curl --silent --show-error --max-time 10 \
      --output "$response" --write-out '%{http_code}' \
      --request GET "http://127.0.0.1:$local_port/api/exchange-rates" \
      --header "x-correlation-id: $correlation_id" \
      --header "traceparent: 00-$trace_id-$span_id-01"
  )"
  [[ "$status" == "200" ]] \
    || fail "$context synthetic App A request returned HTTP ${status:-<none>}"
  jq -e \
    --slurpfile expected "$repo_root/testdata/expected-exchange-rates.json" \
    --arg region "$expected_region" \
    --arg cluster "$expected_cluster" \
    --arg version "$git_sha" '
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
    ' "$response" >/dev/null \
    || fail "$context response does not prove the local App A to App B path"

  stop_port_forward
  printf '%s local App A -> App B exchange-rate request passed (%s/%s).\n' \
    "$context" "$expected_region" "$expected_cluster"
}

prepare_kubeconfig
work_dir="$(mktemp -d "$runtime_dir/verify-workloads.XXXXXX")"

wait_for_workloads gke-risk-usc1
verify_services gke-risk-usc1 app-a-neg-usc1
verify_service_accounts gke-risk-usc1
verify_app_b_rejects_unauthenticated_callers gke-risk-usc1
verify_local_path gke-risk-usc1 us-central1 gke-risk-usc1

wait_for_workloads gke-risk-use4
verify_services gke-risk-use4 app-a-neg-use4
verify_service_accounts gke-risk-use4
verify_app_b_rejects_unauthenticated_callers gke-risk-use4
verify_local_path gke-risk-use4 us-east4 gke-risk-use4

printf 'Verified both regional workload cells at immutable version %s.\n' "$git_sha"

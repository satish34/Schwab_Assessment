#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
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
[[ -f "$repo_root/testdata/request.json" ]] \
  || fail "the canonical synthetic request is missing"

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
  local deployment_json
  local pods_json

  deployment_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get deployment "$deployment" -o json 2>/dev/null
  )" || return 1
  pods_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get pods --selector="app=$deployment" -o json 2>/dev/null
  )" || return 1

  jq -e --arg image "$image" '
    (.metadata.generation <= (.status.observedGeneration // 0)) and
    (.status.replicas == 2) and
    (.status.updatedReplicas == 2) and
    (.status.readyReplicas == 2) and
    (.status.availableReplicas == 2) and
    ((.status.unavailableReplicas // 0) == 0) and
    ([.spec.template.spec.containers[].image] | index($image) != null)
  ' <<<"$deployment_json" >/dev/null || return 1

  jq -e --arg image "$image" '
    (.items | length) == 2 and
    all(.items[];
      (.metadata.deletionTimestamp == null) and
      (.status.phase == "Running") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      all(.spec.containers[]; .image == $image)
    )
  ' <<<"$pods_json" >/dev/null
}

wait_for_workloads() {
  local context="$1"
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$git_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$git_sha"
  local deadline=$((SECONDS + workload_timeout_seconds))

  while ((SECONDS < deadline)); do
    if workload_ready "$context" app-a-gateway "$app_a_image" \
      && workload_ready "$context" app-b-engine "$app_b_image"; then
      printf '%s has exactly two ready App A and two ready App B Pods.\n' "$context"
      return 0
    fi
    sleep 5
  done

  print_diagnostics "$context"
  fail "$context workloads did not reach the exact two-plus-two ready state within ${workload_timeout_seconds}s"
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
    ((.metadata.annotations["cloud.google.com/neg"] // "") == "") and
    ((.spec.externalIPs // []) | length == 0)
  ' <<<"$app_b_json" >/dev/null \
    || fail "$context App B Service is exposed or carries an unexpected NEG annotation"
}

random_hex() {
  local bytes="$1"
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
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
      --request POST "http://127.0.0.1:$local_port/v1/risk" \
      --header 'Content-Type: application/json' \
      --header "x-correlation-id: $correlation_id" \
      --header "traceparent: 00-$trace_id-$span_id-01" \
      --data-binary "@$repo_root/testdata/request.json"
  )"
  [[ "$status" == "200" ]] \
    || fail "$context synthetic App A request returned HTTP ${status:-<none>}"
  jq -e \
    --arg region "$expected_region" \
    --arg cluster "$expected_cluster" \
    --arg version "$git_sha" '
      .requestId == "550e8400-e29b-41d4-a716-446655440000" and
      .score == 48 and
      .decision == "REVIEW" and
      .rulesFired == ["CARD_NOT_PRESENT", "AMOUNT_OVER_1000"] and
      .evaluatedBy.service == "app-b-engine" and
      .evaluatedBy.region == $region and
      .evaluatedBy.cluster == $cluster and
      .evaluatedBy.version == $version
    ' "$response" >/dev/null \
    || fail "$context response does not prove the local App A to App B path"

  stop_port_forward
  printf '%s local App A -> App B request passed (%s/%s).\n' \
    "$context" "$expected_region" "$expected_cluster"
}

prepare_kubeconfig
work_dir="$(mktemp -d "$runtime_dir/verify-workloads.XXXXXX")"

wait_for_workloads gke-risk-usc1
verify_services gke-risk-usc1 app-a-neg-usc1
verify_local_path gke-risk-usc1 us-central1 gke-risk-usc1

wait_for_workloads gke-risk-use4
verify_services gke-risk-use4 app-a-neg-use4
verify_local_path gke-risk-use4 us-east4 gke-risk-use4

printf 'Verified both regional workload cells at immutable version %s.\n' "$git_sha"

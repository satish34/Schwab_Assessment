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
neg_timeout_seconds="${NEG_TIMEOUT_SECONDS:-900}"
neg_poll_seconds="${NEG_POLL_SECONDS:-10}"

neg_specs=(
  'us-central1-a|app-a-neg-usc1|risk-usc1|usc1'
  'us-central1-b|app-a-neg-usc1|risk-usc1|usc1'
  'us-central1-c|app-a-neg-usc1|risk-usc1|usc1'
  'us-east4-a|app-a-neg-use4|risk-use4|use4'
  'us-east4-b|app-a-neg-use4|risk-use4|use4'
  'us-east4-c|app-a-neg-use4|risk-use4|use4'
)

fail() {
  printf 'wait-negs: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
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
[[ "$neg_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((neg_timeout_seconds >= 30 && neg_timeout_seconds <= 3600)) \
  || fail "NEG_TIMEOUT_SECONDS must be between 30 and 3600"
[[ "$neg_poll_seconds" =~ ^[0-9]+$ ]] \
  && ((neg_poll_seconds >= 2 && neg_poll_seconds <= 60)) \
  || fail "NEG_POLL_SECONDS must be between 2 and 60"

for command_name in gcloud git jq kubectl terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done

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

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

# A NEG gate is never allowed to bypass the immutable-image gate.
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

verify_deployed_versions() {
  local context="$1"
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$git_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$git_sha"
  local deployments_json

  deployments_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get deployments app-a-gateway app-b-engine -o json
  )"
  jq -e --arg app_a "$app_a_image" --arg app_b "$app_b_image" '
    ([.items[] | select(.metadata.name == "app-a-gateway")]
      | length == 1) and
    ([.items[] | select(.metadata.name == "app-b-engine")]
      | length == 1) and
    ([.items[] | select(.metadata.name == "app-a-gateway")
        | .spec.template.spec.containers[] | .image] == [$app_a]) and
    ([.items[] | select(.metadata.name == "app-b-engine")
        | .spec.template.spec.containers[] | .image] == [$app_b]) and
    all(.items[];
      (.status.replicas == 2) and
      (.status.readyReplicas == 2) and
      (.status.availableReplicas == 2) and
      ((.status.unavailableReplicas // 0) == 0)
    )
  ' <<<"$deployments_json" >/dev/null \
    || fail "$context is not running the exact verified two-plus-two image version"
}

service_neg_ready() {
  local context="$1"
  local expected_name="$2"
  local expected_zones_csv="$3"
  local service_json

  service_json="$(
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get service app-a-gateway -o json 2>/dev/null
  )" || return 1

  jq -e --arg name "$expected_name" --arg zones "$expected_zones_csv" '
    ((.metadata.annotations["cloud.google.com/neg"] | fromjson)
      == {"exposed_ports":{"8080":{"name":$name}}}) and
    ((.metadata.annotations["cloud.google.com/neg-status"] | fromjson) as $status
      | ($status.network_endpoint_groups == {"8080":$name}) and
        (($status.zones | sort | join(",")) == $zones))
  ' <<<"$service_json" >/dev/null 2>&1
}

inventory_is_exact() {
  local inventory_json="$1"

  jq -e '
    def leaf: split("/")[-1];
    [ .[]
      | {
          name,
          zone: (.zone | leaf),
          type: .networkEndpointType
        }
    ] | sort_by(.zone, .name)
      == ([
        {"name":"app-a-neg-usc1","zone":"us-central1-a","type":"GCE_VM_IP_PORT"},
        {"name":"app-a-neg-usc1","zone":"us-central1-b","type":"GCE_VM_IP_PORT"},
        {"name":"app-a-neg-usc1","zone":"us-central1-c","type":"GCE_VM_IP_PORT"},
        {"name":"app-a-neg-use4","zone":"us-east4-a","type":"GCE_VM_IP_PORT"},
        {"name":"app-a-neg-use4","zone":"us-east4-b","type":"GCE_VM_IP_PORT"},
        {"name":"app-a-neg-use4","zone":"us-east4-c","type":"GCE_VM_IP_PORT"}
      ] | sort_by(.zone, .name))
  ' <<<"$inventory_json" >/dev/null
}

read_endpoint_count() {
  local zone="$1"
  local name="$2"
  local subnet="$3"
  local description_json
  local endpoints_json

  description_json="$(
    timeout --foreground --signal=INT 30s \
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" \
      --project="$PROJECT_ID" \
      compute network-endpoint-groups describe "$name" \
      --zone="$zone" \
      --format=json 2>/dev/null
  )" || return 1
  jq -e --arg name "$name" --arg zone "$zone" --arg subnet "$subnet" '
    def leaf: split("/")[-1];
    (.name == $name) and
    ((.zone | leaf) == $zone) and
    (.networkEndpointType == "GCE_VM_IP_PORT") and
    ((.network | leaf) == "risk-vpc") and
    ((.subnetwork | leaf) == $subnet)
  ' <<<"$description_json" >/dev/null || return 1

  endpoints_json="$(
    timeout --foreground --signal=INT 30s \
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" \
      --project="$PROJECT_ID" \
      compute network-endpoint-groups list-network-endpoints "$name" \
      --zone="$zone" \
      --format=json 2>/dev/null
  )" || return 1
  jq -e '
    all(.[];
      ((.networkEndpoint.ipAddress // "") | length) > 0 and
      (.networkEndpoint.port == 8080)
    )
  ' <<<"$endpoints_json" >/dev/null || return 1

  jq -r 'length' <<<"$endpoints_json"
}

print_diagnostics() {
  local context
  local spec
  local zone
  local name
  local subnet
  local region_key

  for context in gke-risk-usc1 gke-risk-use4; do
    printf '\nService and NEG-controller diagnostics for %s:\n' "$context" >&2
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get service app-a-gateway -o yaml >&2 || true
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 >&2 || true
  done

  printf '\nLive zonal NEG inventory:\n' >&2
  timeout --foreground --signal=INT 30s \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    compute network-endpoint-groups list \
    --format='table(name,zone.basename(),networkEndpointType,size)' >&2 || true

  for spec in "${neg_specs[@]}"; do
    IFS='|' read -r zone name subnet region_key <<<"$spec"
    printf '\nEndpoints for %s/%s:\n' "$zone" "$name" >&2
    timeout --foreground --signal=INT 30s \
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" \
      --project="$PROJECT_ID" \
      compute network-endpoint-groups list-network-endpoints "$name" \
      --zone="$zone" \
      --format='table(networkEndpoint.ipAddress,networkEndpoint.port)' >&2 || true
  done
}

prepare_kubeconfig
verify_deployed_versions gke-risk-usc1
verify_deployed_versions gke-risk-use4

deadline=$((SECONDS + neg_timeout_seconds))
declare -A endpoint_counts=()
while ((SECONDS < deadline)); do
  annotations_ready=0
  inventory_ready=0
  endpoints_ready=1
  usc1_total=0
  use4_total=0
  endpoint_counts=()

  if service_neg_ready \
      gke-risk-usc1 app-a-neg-usc1 \
      'us-central1-a,us-central1-b,us-central1-c' \
    && service_neg_ready \
      gke-risk-use4 app-a-neg-use4 \
      'us-east4-a,us-east4-b,us-east4-c'; then
    annotations_ready=1
  fi

  if inventory_json="$(
      timeout --foreground --signal=INT 30s \
        gcloud --configuration="$GCLOUD_CONFIGURATION" \
        --account="$expected_account" \
        --project="$PROJECT_ID" \
        compute network-endpoint-groups list \
        --format=json 2>/dev/null
    )" \
    && inventory_is_exact "$inventory_json"; then
    inventory_ready=1

    for spec in "${neg_specs[@]}"; do
      IFS='|' read -r zone name subnet region_key <<<"$spec"
      if count="$(read_endpoint_count "$zone" "$name" "$subnet")"; then
        endpoint_counts["$zone"]="$count"
        if [[ "$region_key" == "usc1" ]]; then
          usc1_total=$((usc1_total + count))
        else
          use4_total=$((use4_total + count))
        fi
      else
        endpoints_ready=0
        break
      fi
    done
  else
    endpoints_ready=0
  fi

  if ((annotations_ready == 1 \
      && inventory_ready == 1 \
      && endpoints_ready == 1 \
      && usc1_total >= 2 \
      && use4_total >= 2)); then
    printf 'ZONE              NEG                ENDPOINTS\n'
    for spec in "${neg_specs[@]}"; do
      IFS='|' read -r zone name subnet region_key <<<"$spec"
      printf '%-17s %-18s %s\n' "$zone" "$name" "${endpoint_counts[$zone]}"
    done
    printf 'Verified six zonal GCE_VM_IP_PORT NEGs: us-central1=%s endpoints, us-east4=%s endpoints.\n' \
      "$usc1_total" "$use4_total"
    exit 0
  fi

  sleep "$neg_poll_seconds"
done

print_diagnostics
fail "NEG status, exact six-object inventory, and two-endpoint-per-region gate did not pass within ${neg_timeout_seconds}s"

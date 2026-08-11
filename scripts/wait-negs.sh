#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
app_a_namespace="currency-app-a"
app_b_namespace="currency-app-b"
runtime_dir="$repo_root/.tmp"
kubeconfig="${VERIFIER_KUBECONFIG:-$runtime_dir/kubeconfig-verifier}"
kubeconfig_candidate=""
neg_timeout_seconds="${NEG_TIMEOUT_SECONDS:-900}"
neg_poll_seconds="${NEG_POLL_SECONDS:-10}"

neg_specs=(
  'us-central1-a|app-a-neg-usc1|risk-usc1|usc1|gke-risk-usc1|a'
  'us-central1-b|app-a-neg-usc1|risk-usc1|usc1|gke-risk-usc1|b'
  'us-central1-c|app-a-neg-usc1|risk-usc1|usc1|gke-risk-usc1|c'
  'us-east4-a|app-a-neg-use4|risk-use4|use4|gke-risk-use4|a'
  'us-east4-b|app-a-neg-use4|risk-use4|use4|gke-risk-use4|b'
  'us-east4-c|app-a-neg-use4|risk-use4|use4|gke-risk-use4|c'
)

fail() {
  printf 'wait-negs: %s\n' "$*" >&2
  exit 1
}

case "$kubeconfig" in
  "$runtime_dir"/kubeconfig-verifier | "$runtime_dir"/kubeconfig-verifier-gate-*) ;;
  *) fail "VERIFIER_KUBECONFIG must stay under the ignored runtime directory" ;;
esac

cleanup() {
  local exit_code=$?

  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

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

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

# A NEG gate is never allowed to bypass the immutable-image gate.
timeout --foreground --signal=INT 10m \
  bash scripts/verify-images.sh "$app_a_sha" "$app_b_sha"

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

  kubeconfig_candidate="$(mktemp "$runtime_dir/kubeconfig-verifier.new.XXXXXX")"
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
  local zone_a="$2"
  local zone_b="$3"
  local zone_c="$4"
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$app_a_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$app_b_sha"
  local app_a_deployments_json
  local app_b_deployment_json
  local app_a_hpas_json
  local app_b_hpa_json
  local app_a_pods_json
  local app_b_pods_json

  app_a_deployments_json="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get deployments --selector='app=app-a-gateway' -o json 2>/dev/null
  )" || return 1
  app_b_deployment_json="$(
    kubectl --context="$context" --namespace="$app_b_namespace" --request-timeout=20s \
      get deployment app-b-engine -o json 2>/dev/null
  )" || return 1
  app_a_hpas_json="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get horizontalpodautoscalers \
        app-a-gateway-a app-a-gateway-b app-a-gateway-c -o json 2>/dev/null
  )" || return 1
  app_b_hpa_json="$(
    kubectl --context="$context" --namespace="$app_b_namespace" --request-timeout=20s \
      get horizontalpodautoscaler app-b-engine -o json 2>/dev/null
  )" || return 1
  app_a_pods_json="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get pods --selector='app=app-a-gateway' -o json 2>/dev/null
  )" || return 1
  app_b_pods_json="$(
    kubectl --context="$context" --namespace="$app_b_namespace" --request-timeout=20s \
      get pods --selector='app=app-b-engine' -o json 2>/dev/null
  )" || return 1

  jq -e \
    --arg image "$app_a_image" \
    --arg version "$app_a_sha" \
    --arg zone_a "$zone_a" \
    --arg zone_b "$zone_b" \
    --arg zone_c "$zone_c" '
    def literal_env($item; $name; $value):
      [$item.spec.template.spec.containers[0].env[]?
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
      (.spec.template.spec.nodeSelector["topology.kubernetes.io/zone"]
        == expected_zone($shard)) and
      ([.spec.template.spec.containers[].image] == [$image]) and
      literal_env(.; "SERVICE_VERSION"; $version) and
      literal_env(.; "APP_B_BASE_URL"; "http://app-b-engine.currency-app-b.svc.cluster.local:8080") and
      (.status.replicas == $replicas) and
      (.status.updatedReplicas == $replicas) and
      (.status.readyReplicas == $replicas) and
      (.status.availableReplicas == $replicas) and
      ((.status.unavailableReplicas // 0) == 0)
    )
  ' <<<"$app_a_deployments_json" >/dev/null || return 1

  jq -e --arg image "$app_b_image" --arg version "$app_b_sha" '
    def literal_env($name; $value):
      [.spec.template.spec.containers[0].env[]?
        | select(.name == $name and .value == $value)] | length == 1;
    (.metadata.name == "app-b-engine") and
    (.spec.replicas >= 2 and .spec.replicas <= 6) and
    (.metadata.generation <= (.status.observedGeneration // 0)) and
    ([.spec.template.spec.containers[].image] == [$image]) and
    literal_env("SERVICE_VERSION"; $version) and
    (.status.replicas == .spec.replicas) and
    (.status.updatedReplicas == .spec.replicas) and
    (.status.readyReplicas == .spec.replicas) and
    (.status.availableReplicas == .spec.replicas) and
    ((.status.unavailableReplicas // 0) == 0)
  ' <<<"$app_b_deployment_json" >/dev/null || return 1

  jq -e '
    ([.items[].metadata.name] | sort) == [
      "app-a-gateway-a",
      "app-a-gateway-b",
      "app-a-gateway-c"
    ] and
    all(.items[];
      (.spec.minReplicas == 1) and
      (.spec.maxReplicas == 2) and
      (.status.currentReplicas >= 1 and .status.currentReplicas <= 2) and
      (.status.desiredReplicas == .status.currentReplicas)
    )
  ' <<<"$app_a_hpas_json" >/dev/null || return 1

  jq -e '
    (.metadata.name == "app-b-engine") and
    (.spec.minReplicas == 2) and
    (.spec.maxReplicas == 6) and
    (.status.currentReplicas >= 2 and .status.currentReplicas <= 6) and
    (.status.desiredReplicas == .status.currentReplicas)
  ' <<<"$app_b_hpa_json" >/dev/null || return 1

  jq -e \
    --arg image "$app_a_image" \
    --arg zone_a "$zone_a" \
    --arg zone_b "$zone_b" \
    --arg zone_c "$zone_c" '
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
  ' <<<"$app_a_pods_json" >/dev/null || return 1

  replicas="$(jq -r '.spec.replicas' <<<"$app_b_deployment_json" | tr -d '\r')"
  jq -e --arg image "$app_b_image" --argjson replicas "$replicas" '
    (.items | length) == $replicas and
    all(.items[];
      (.metadata.deletionTimestamp == null) and
      (.status.phase == "Running") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      ([.spec.containers[].image] == [$image]) and
      ([.status.containerStatuses[]?.image] == [$image]) and
      all(.status.containerStatuses[]?; .ready == true)
    )
  ' <<<"$app_b_pods_json" >/dev/null || return 1

}

service_neg_ready() {
  local context="$1"
  local expected_name="$2"
  local expected_zones_csv="$3"
  local service_json

  service_json="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
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

read_ready_pod_endpoints() {
  local context="$1"
  local shard="$2"
  local zone="$3"
  local image="$4"
  local pods_json
  local node_name
  local actual_zone

  pods_json="$(
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get pods --selector="app=app-a-gateway,app-a-shard=$shard" \
      -o json 2>/dev/null
  )" || return 1

  jq -e --arg zone "$zone" --arg image "$image" '
    ((.items | length) >= 1 and (.items | length) <= 2) and
    (([.items[].status.podIP] | unique | length) == (.items | length)) and
    all(.items[];
      (.metadata.deletionTimestamp == null) and
      (.status.phase == "Running") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      ([.spec.containers[].image] == [$image]) and
      ([.status.containerStatuses[]?.image] == [$image]) and
      all(.status.containerStatuses[]?; .ready == true) and
      (.spec.nodeSelector["topology.kubernetes.io/zone"] == $zone) and
      ((.spec.nodeName // "") | length > 0) and
      ((.status.podIP // "") | length > 0)
    )
  ' <<<"$pods_json" >/dev/null || return 1

  while IFS= read -r node_name; do
    [[ -n "$node_name" ]] || return 1
    actual_zone="$(
      kubectl --context="$context" --request-timeout=20s get node "$node_name" \
        -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null
    )" || return 1
    [[ "$actual_zone" == "$zone" ]] || return 1
  done < <(jq -r '.items[].spec.nodeName' <<<"$pods_json" | tr -d '\r')

  jq -c '
    [.items[] | {ipAddress:.status.podIP, port:8080}]
    | sort_by(.ipAddress, .port)
  ' <<<"$pods_json" | tr -d '\r'
}

read_neg_endpoints() {
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
    ) and
    (([.[].networkEndpoint.ipAddress] | unique | length) == length)
  ' <<<"$endpoints_json" >/dev/null || return 1

  jq -c '
    [.[] | {
      ipAddress:.networkEndpoint.ipAddress,
      port:(.networkEndpoint.port | tonumber)
    }] | sort_by(.ipAddress, .port)
  ' <<<"$endpoints_json" | tr -d '\r'
}

print_diagnostics() {
  local context
  local spec
  local zone
  local name
  local subnet
  local region_key
  local context_name
  local shard

  for context in gke-risk-usc1 gke-risk-use4; do
    printf '\nService and NEG-controller diagnostics for %s:\n' "$context" >&2
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get service app-a-gateway -o yaml >&2 || true
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get deployments,horizontalpodautoscalers,pods -o wide >&2 || true
    kubectl --context="$context" --namespace="$app_a_namespace" --request-timeout=20s \
      get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 >&2 || true
    printf '\nApp B diagnostics for %s:\n' "$context" >&2
    kubectl --context="$context" --namespace="$app_b_namespace" --request-timeout=20s \
      get deployments,horizontalpodautoscalers,pods -o wide >&2 || true
  done

  printf '\nLive zonal NEG inventory:\n' >&2
  timeout --foreground --signal=INT 30s \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    compute network-endpoint-groups list \
    --format='table(name,zone.basename(),networkEndpointType,size)' >&2 || true

  for spec in "${neg_specs[@]}"; do
    IFS='|' read -r zone name subnet region_key context_name shard <<<"$spec"
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

deadline=$((SECONDS + neg_timeout_seconds))
declare -A endpoint_counts=()
declare -A expected_endpoint_sets=()
declare -A actual_endpoint_sets=()
while ((SECONDS < deadline)); do
  workloads_ready=0
  annotations_ready=0
  inventory_ready=0
  endpoints_ready=1
  usc1_total=0
  use4_total=0
  endpoint_counts=()
  expected_endpoint_sets=()
  actual_endpoint_sets=()

  if verify_deployed_versions \
      gke-risk-usc1 us-central1-a us-central1-b us-central1-c \
    && verify_deployed_versions \
      gke-risk-use4 us-east4-a us-east4-b us-east4-c; then
    workloads_ready=1
  fi

  if service_neg_ready \
      gke-risk-usc1 app-a-neg-usc1 \
      'us-central1-a,us-central1-b,us-central1-c' \
    && service_neg_ready \
      gke-risk-use4 app-a-neg-use4 \
      'us-east4-a,us-east4-b,us-east4-c'; then
    annotations_ready=1
  fi

  if ((workloads_ready == 1)) \
    && inventory_json="$(
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
      IFS='|' read -r zone name subnet region_key context_name shard <<<"$spec"
      app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$app_a_sha"
      if expected_endpoints="$(
          read_ready_pod_endpoints \
            "$context_name" "$shard" "$zone" "$app_a_image"
        )" \
        && actual_endpoints="$(read_neg_endpoints "$zone" "$name" "$subnet")" \
        && [[ "$actual_endpoints" == "$expected_endpoints" ]]; then
        expected_endpoint_sets["$zone"]="$expected_endpoints"
        actual_endpoint_sets["$zone"]="$actual_endpoints"
        count="$(jq -r 'length' <<<"$actual_endpoints" | tr -d '\r')"
        endpoint_counts["$zone"]="$count"
        if ((count < 1 || count > 2)); then
          endpoints_ready=0
          break
        fi
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
      && workloads_ready == 1 \
      && inventory_ready == 1 \
      && endpoints_ready == 1 \
      && usc1_total >= 3 \
      && usc1_total <= 6 \
      && use4_total >= 3 \
      && use4_total <= 6)); then
    printf 'ZONE              NEG                ENDPOINTS\n'
    for spec in "${neg_specs[@]}"; do
      IFS='|' read -r zone name subnet region_key context_name shard <<<"$spec"
      printf '%-17s %-18s %s\n' "$zone" "$name" "${endpoint_counts[$zone]}"
    done
    printf 'Verified six zonal GCE_VM_IP_PORT NEGs exactly match ready App A Pod IP:8080 endpoints: us-central1=%s, us-east4=%s.\n' \
      "$usc1_total" "$use4_total"
    exit 0
  fi

  sleep "$neg_poll_seconds"
done

print_diagnostics
fail "NEG status, reconciled workloads, and exact ready-Pod endpoint membership did not pass within ${neg_timeout_seconds}s"

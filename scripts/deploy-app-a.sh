#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
namespace="currency-app-a"
counterpart_namespace="currency-app-b"
runtime_dir="$repo_root/.tmp"
kubeconfig="$runtime_dir/kubeconfig-app-a"
kubeconfig_candidate=""
work_dir=""
target_sha=""
counterpart_sha=""
defer_combined_gate="${DEFER_COMBINED_GATE:-0}"
previous_sha=""
bootstrap_release=0
deployer_email=""
central_pid=""
east_pid=""
declare -a mutated_contexts=()

fail() {
  printf 'deploy-app-a: %s\n' "$*" >&2
  exit 1
}

rollout_app_a() {
  local context="$1"
  local deployment
  for deployment in app-a-gateway-a app-a-gateway-b app-a-gateway-c; do
    kubectl --context="$context" --namespace="$namespace" --request-timeout=60s \
      rollout status "deployment/$deployment" --timeout=10m
  done
}

rollback_mutated_cells() {
  local index entry context rollback_manifest target_manifest

  ((${#mutated_contexts[@]} > 0)) || return 0
  if ((bootstrap_release == 1)); then
    printf 'App A bootstrap failed; deleting only workload objects created by this lane.\n' >&2
  else
    [[ "$previous_sha" != "$target_sha" ]] || return 0
    printf 'App A deployment failed; restoring immutable image version %s.\n' \
      "$previous_sha" >&2
  fi
  for ((index = ${#mutated_contexts[@]} - 1; index >= 0; index--)); do
    entry="${mutated_contexts[$index]}"
    context="${entry%%|*}"
    target_manifest="${entry#*|}"
    if ((bootstrap_release == 1)); then
      kubectl --context="$context" --request-timeout=60s \
        delete -f "$target_manifest" --ignore-not-found=true --wait=true --timeout=5m >&2 \
        || printf 'Automatic App A bootstrap cleanup needs attention in %s.\n' "$context" >&2
    else
      rollback_manifest="${target_manifest/target-/rollback-}"
      kubectl --context="$context" --request-timeout=60s apply -f "$rollback_manifest" >&2 \
        && rollout_app_a "$context" >&2 \
        || printf 'Automatic App A rollback needs attention in %s.\n' "$context" >&2
    fi
  done
}

cleanup() {
  local exit_code=$?
  set +e
  for child_pid in "$central_pid" "$east_pid"; do
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
      kill "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
    fi
  done
  if ((exit_code != 0)); then
    rollback_mutated_cells
  fi
  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/deploy-app-a.*)
        rm -f -- "$work_dir"/*
        rmdir -- "$work_dir" 2>/dev/null || true
        ;;
    esac
  fi
  trap - EXIT INT TERM
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s FULL_APP_A_GIT_SHA EXPECTED_APP_B_GIT_SHA\n' "$0" >&2
  exit 2
fi
: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

target_sha="$1"
counterpart_sha="$2"
deployer_email="currency-app-a-deployer@$PROJECT_ID.iam.gserviceaccount.com"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project, received $PROJECT_ID"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"
[[ "$target_sha" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$counterpart_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "both release versions must be full lowercase 40-character Git SHAs"
[[ "$defer_combined_gate" == "0" || "$defer_combined_gate" == "1" ]] \
  || fail "DEFER_COMBINED_GATE must be 0 or 1"

for command_name in gcloud git jq kubectl sed timeout; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
for sha in "$target_sha" "$counterpart_sha"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null \
    || fail "Git SHA $sha is not a commit in this repository"
done
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
  || fail "the worktree must be clean so deployed manifests are tied to committed source"
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] \
    || fail "$override_name must be unset so deployer impersonation is authoritative"
done

active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected gcloud account $expected_account, found ${active_account:-<none>}"
configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected gcloud project $PROJECT_ID, found ${configured_project:-<none>}"

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
timeout --foreground --signal=INT 5m bash scripts/verify-image.sh app-a "$target_sha"
timeout --foreground --signal=INT 5m bash scripts/verify-image.sh app-b "$counterpart_sha"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$deployer_email"

mkdir -p "$runtime_dir"
git check-ignore --quiet -- "$kubeconfig" \
  || fail "the App A kubeconfig path is not ignored by Git"

set_kubeconfig() {
  local path="$1"
  case "$(uname -s)" in
    MINGW* | MSYS*) KUBECONFIG="$(cygpath -w "$path")" ;;
    *) KUBECONFIG="$path" ;;
  esac
  export KUBECONFIG
}

prepare_context() {
  local context="$1" cluster="$2" region="$3" source_context
  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      --impersonate-service-account="$deployer_email" \
      container clusters get-credentials "$cluster" --region="$region"
  source_context="$(kubectl config current-context | tr -d '\r')"
  [[ -n "$source_context" ]] || fail "gcloud did not create a context for $cluster"
  if [[ "$source_context" != "$context" ]]; then
    kubectl config rename-context "$source_context" "$context" >/dev/null
  fi
}

prepare_kubeconfig() {
  local contexts
  kubeconfig_candidate="$(mktemp "$runtime_dir/kubeconfig-app-a.new.XXXXXX")"
  chmod 600 "$kubeconfig_candidate" 2>/dev/null || true
  printf '%s\n' \
    'apiVersion: v1' 'kind: Config' 'preferences: {}' \
    'clusters: []' 'contexts: []' 'users: []' >"$kubeconfig_candidate"
  set_kubeconfig "$kubeconfig_candidate"
  prepare_context gke-risk-usc1 gke-risk-usc1 us-central1
  prepare_context gke-risk-use4 gke-risk-use4 us-east4
  contexts="$(kubectl config get-contexts -o name | tr -d '\r' | sort)"
  [[ "$contexts" == $'gke-risk-usc1\ngke-risk-use4' ]] \
    || fail "the App A kubeconfig does not contain exactly the two expected contexts"
  mv -f -- "$kubeconfig_candidate" "$kubeconfig"
  kubeconfig_candidate=""
  chmod 600 "$kubeconfig" 2>/dev/null || true
  set_kubeconfig "$kubeconfig"
}

expect_can_i() {
  local context="$1" expected="$2" verb="$3" resource="$4" target_namespace="$5"
  local actual command_status
  set +e
  actual="$(kubectl --context="$context" --namespace="$target_namespace" \
    --request-timeout=20s auth can-i "$verb" "$resource" | tr -d '\r')"
  command_status=$?
  set -e
  actual="${actual%%[[:space:]]*}"
  [[ "$actual" == "yes" && "$command_status" == "0" \
    || "$actual" == "no" && "$command_status" == "1" ]] \
    || fail "$context could not evaluate RBAC for '$verb $resource' in $target_namespace"
  [[ "$actual" == "$expected" ]] \
    || fail "$context expected RBAC '$expected' for '$verb $resource' in $target_namespace, received '$actual'"
}

verify_deployer_isolation() {
  local context="$1" resource
  for resource in deployments.apps horizontalpodautoscalers.autoscaling poddisruptionbudgets.policy; do
    for verb in get list watch create update patch delete; do
      expect_can_i "$context" yes "$verb" "$resource" "$namespace"
    done
  done
  expect_can_i "$context" yes get pods "$namespace"
  expect_can_i "$context" yes get pods/log "$namespace"
  for resource in configmaps services serviceaccounts networkpolicies.networking.k8s.io \
    roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io resourcequotas; do
    for verb in get list watch create update patch delete; do
      expect_can_i "$context" no "$verb" "$resource" "$namespace"
    done
  done
  for verb in get list watch create update patch delete; do
    expect_can_i "$context" no "$verb" secrets "$namespace"
    expect_can_i "$context" no "$verb" secrets "$counterpart_namespace"
  done
  for verb in create update patch delete; do
    expect_can_i "$context" no "$verb" pods "$namespace"
  done
  for subresource in pods/portforward pods/exec pods/attach; do
    expect_can_i "$context" no create "$subresource" "$namespace"
    expect_can_i "$context" no create "$subresource" "$counterpart_namespace"
  done
  for resource in deployments.apps horizontalpodautoscalers.autoscaling \
    poddisruptionbudgets.policy pods pods/log configmaps services serviceaccounts \
    networkpolicies.networking.k8s.io roles.rbac.authorization.k8s.io \
    rolebindings.rbac.authorization.k8s.io resourcequotas; do
    for verb in get list watch create update patch delete; do
      expect_can_i "$context" no "$verb" "$resource" "$counterpart_namespace"
    done
  done
}

render_release() {
  local region="$1" version="$2" output="$3"
  local image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$version"
  kubectl kustomize "$repo_root/k8s/overlays/$region/app-a" \
    | sed -e "s/PROJECT_ID/$PROJECT_ID/g" -e "s/GIT_SHA/$version/g" >"$output"
  ! grep -Eq \
    '(^|[^A-Z0-9_])PROJECT_ID([^A-Z0-9_]|$)|(^|[^A-Z0-9_])GIT_SHA([^A-Z0-9_]|$)|app-a-image|:latest([[:space:]]|$)' \
    "$output" || fail "$region App A render contains a placeholder or latest tag"
  [[ "$(grep -Fc -- "image: $image" "$output")" == "3" ]] \
    && [[ "$(grep -Ec '^kind: Deployment$' "$output")" == "3" ]] \
    && [[ "$(grep -Ec '^kind: HorizontalPodAutoscaler$' "$output")" == "3" ]] \
    && [[ "$(grep -Ec '^kind: PodDisruptionBudget$' "$output")" == "1" ]] \
    || fail "$region App A workload inventory changed"
  ! grep -Eq '^kind: (ConfigMap|Namespace|NetworkPolicy|ResourceQuota|Role|RoleBinding|Secret|Service|ServiceAccount)$' "$output" \
    || fail "$region App A render includes an Ops-owned resource"
  ! grep -Fq -- 'namespace: currency-app-b' "$output" \
    && grep -Fq -- 'namespace: currency-app-a' "$output" \
    || fail "$region App A render crosses its namespace boundary"
  [[ "$(grep -Fc -- 'name: SERVICE_VERSION' "$output")" == "3" ]] \
    && [[ "$(grep -Fc -- "value: $version" "$output")" == "3" ]] \
    && [[ "$(grep -Fc -- 'value: http://app-b-engine.currency-app-b.svc.cluster.local:8080' "$output")" == "3" ]] \
    && [[ "$(grep -Fc -- 'value: google-id-token' "$output")" == "3" ]] \
    && ! grep -Fq -- 'value: disabled' "$output" \
    || fail "$region App A render lost its immutable version or signed cross-namespace path"
}

read_current_version() {
  local context="$1" deployments_json
  deployments_json="$(kubectl --context="$context" --namespace="$namespace" \
    --request-timeout=20s get deployments --selector='app=app-a-gateway' -o json)"
  jq -er --arg prefix "us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:" '
    if (.items | length) == 0 then ""
    elif ([.items[].metadata.name] | sort) != [
      "app-a-gateway-a", "app-a-gateway-b", "app-a-gateway-c"
    ] then error("unexpected App A deployment inventory")
    else [.items[].spec.template.spec.containers[]
      | select(.name == "app-a-gateway") | .image
      | select(startswith($prefix)) | ltrimstr($prefix)] | unique
      | if length == 1 and (.[0] | test("^[0-9a-f]{40}$")) then .[0]
        else error("App A does not use one immutable version") end
    end
  ' <<<"$deployments_json"
}

verify_app_a() {
  local context="$1" zone_a="$2" zone_b="$3" zone_c="$4"
  local image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$target_sha" deployments_json
  rollout_app_a "$context"
  deployments_json="$(kubectl --context="$context" --namespace="$namespace" \
    --request-timeout=20s get deployments --selector='app=app-a-gateway' -o json)"
  jq -e --arg image "$image" --arg version "$target_sha" \
    --arg zone_a "$zone_a" --arg zone_b "$zone_b" --arg zone_c "$zone_c" '
    def zone($name): if $name == "app-a-gateway-a" then $zone_a
      elif $name == "app-a-gateway-b" then $zone_b else $zone_c end;
    def env($item; $name; $value):
      [$item.spec.template.spec.containers[0].env[]?
        | select(.name == $name and .value == $value)] | length == 1;
    ([.items[].metadata.name] | sort) == [
      "app-a-gateway-a", "app-a-gateway-b", "app-a-gateway-c"] and
    all(.items[];
      (.spec.replicas >= 1 and .spec.replicas <= 2) and
      (.status.updatedReplicas == .spec.replicas) and
      (.status.readyReplicas == .spec.replicas) and
      ((.status.unavailableReplicas // 0) == 0) and
      ([.spec.template.spec.containers[].image] == [$image]) and
      env(.; "SERVICE_VERSION"; $version) and
      env(.; "APP_B_BASE_URL"; "http://app-b-engine.currency-app-b.svc.cluster.local:8080") and
      env(.; "APP_B_AUTH_MODE"; "google-id-token") and
      (.spec.template.spec.serviceAccountName == "app-a-gateway") and
      (.spec.template.spec.nodeSelector["topology.kubernetes.io/zone"] == zone(.metadata.name)))
  ' <<<"$deployments_json" >/dev/null || fail "$context App A did not reconcile to $target_sha"
}

verify_signed_path_log() {
  local context="$1" logs_file="$work_dir/signed-path-$context.log" deadline
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    kubectl --context="$context" --namespace="$namespace" --request-timeout=30s \
      logs --selector='app=app-a-gateway' --all-containers=true \
      --since=5m --tail=3000 >"$logs_file" 2>/dev/null || true
    if jq -Rse --arg version "$target_sha" '
      [split("\n")[] | fromjson?] | any(.[];
        .service == "app-a-gateway" and .service_version == $version and
        .log_type == "dependency_probe" and .status_code == 200 and
        .decision == "RATES_RETURNED")
    ' "$logs_file" >/dev/null 2>&1; then
      printf '%s App A %s recorded a successful signed App B probe.\n' "$context" "$target_sha"
      return 0
    fi
    sleep 2
  done
  fail "$context App A did not record a successful signed dependency probe within 600s"
}

deploy_region() {
  local context="$1" manifest="$2" zone_a="$3" zone_b="$4" zone_c="$5"
  kubectl --context="$context" --request-timeout=60s apply -f "$manifest"
  verify_app_a "$context" "$zone_a" "$zone_b" "$zone_c"
  verify_signed_path_log "$context"
}

prepare_kubeconfig
verify_deployer_isolation gke-risk-usc1
verify_deployer_isolation gke-risk-use4
work_dir="$(mktemp -d "$runtime_dir/deploy-app-a.XXXXXX")"
central_previous="$(read_current_version gke-risk-usc1)"
east_previous="$(read_current_version gke-risk-use4)"
[[ "$central_previous" == "$east_previous" ]] \
  || fail "App A must start absent or at one version in both cells"
previous_sha="$central_previous"
[[ -n "$previous_sha" ]] || bootstrap_release=1

render_release us-central1 "$target_sha" "$work_dir/target-us-central1.yaml"
render_release us-east4 "$target_sha" "$work_dir/target-us-east4.yaml"
if ((bootstrap_release == 0)) && [[ "$previous_sha" != "$target_sha" ]]; then
  render_release us-central1 "$previous_sha" "$work_dir/rollback-us-central1.yaml"
  render_release us-east4 "$previous_sha" "$work_dir/rollback-us-east4.yaml"
fi

mutated_contexts+=("gke-risk-usc1|$work_dir/target-us-central1.yaml")
mutated_contexts+=("gke-risk-use4|$work_dir/target-us-east4.yaml")
deploy_region gke-risk-usc1 "$work_dir/target-us-central1.yaml" \
  us-central1-a us-central1-b us-central1-c >"$work_dir/us-central1.log" 2>&1 &
central_pid=$!
deploy_region gke-risk-use4 "$work_dir/target-us-east4.yaml" \
  us-east4-a us-east4-b us-east4-c >"$work_dir/us-east4.log" 2>&1 &
east_pid=$!
set +e
wait "$central_pid"; central_status=$?; central_pid=""
wait "$east_pid"; east_status=$?; east_pid=""
set -e
cat "$work_dir/us-central1.log"
cat "$work_dir/us-east4.log"
((central_status == 0 && east_status == 0)) \
  || fail "one or both App A regional rollouts failed"

if [[ "$defer_combined_gate" == "0" ]]; then
  if ! (
    unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT KUBECONFIG
    bash scripts/verify-deployment-gates.sh "$target_sha" "$counterpart_sha"
  ); then
    fail "the authoritative App A/App B pair gate failed after the App A rollout"
  fi
fi
mutated_contexts=()
if [[ "$defer_combined_gate" == "1" ]]; then
  printf 'App A lane passed provisionally at %s; the aggregate release owns the App B %s combined gate.\n' \
    "$target_sha" "$counterpart_sha"
else
  printf 'App A deployment passed its authoritative App A %s / App B %s combined gate.\n' \
    "$target_sha" "$counterpart_sha"
fi
if ((bootstrap_release == 0)) && [[ "$previous_sha" != "$target_sha" ]]; then
  printf 'Image rollback command: bash scripts/deploy-app-a.sh %s %s\n' \
    "$previous_sha" "$counterpart_sha"
fi

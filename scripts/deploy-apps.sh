#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/platform-cutover-contract.sh"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
runtime_dir="$repo_root/.tmp"
kubeconfig="$runtime_dir/kubeconfig-platform"
kubeconfig_candidate=""
work_dir=""
app_a_pid=""
app_b_pid=""
platform_central_pid=""
platform_east_pid=""
restore_required=0
platform_cleanup_scope=""
previous_app_a_sha=""
previous_app_b_sha=""
bootstrap_mode=0
platform_absent=0
platform_expansion=0

fail() {
  printf 'deploy-apps: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  set +e
  for child_pid in "$app_a_pid" "$app_b_pid" "$platform_central_pid" "$platform_east_pid"; do
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
      kill "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
    fi
  done
  if [[ $exit_code -ne 0 && -n "$platform_cleanup_scope" ]]; then
    cleanup_platform_apply \
      || printf 'deploy-apps: platform apply cleanup needs operator attention.\n' >&2
  fi
  if ((exit_code != 0 && restore_required == 1)); then
    restore_previous_pair || printf 'deploy-apps: coordinated rollback needs operator attention.\n' >&2
  fi
  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/deploy-apps.*)
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

for command_name in gcloud git jq kubectl sed timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
for sha in "$app_a_sha" "$app_b_sha"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null \
    || fail "Git SHA $sha is not a commit in this repository"
done
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
  || fail "the worktree must be clean before any platform or workload mutation"
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] \
    || fail "$override_name must be unset so the named operator and deployer identities are authoritative"
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

# Immutable image existence and provenance are the mutation boundary.
timeout --foreground --signal=INT 10m \
  bash scripts/verify-images.sh "$app_a_sha" "$app_b_sha"

mkdir -p "$runtime_dir"
git check-ignore --quiet -- "$kubeconfig" \
  || fail "the repo-local platform kubeconfig path is not ignored by Git"

set_kubeconfig() {
  local path="$1"
  case "$(uname -s)" in
    MINGW* | MSYS*) KUBECONFIG="$(cygpath -w "$path")" ;;
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
      --account="$expected_account" --project="$PROJECT_ID" \
      container clusters get-credentials "$cluster" --region="$region"
  source_context="$(kubectl config current-context | tr -d '\r')"
  [[ -n "$source_context" ]] || fail "gcloud did not create a context for $cluster"
  if [[ "$source_context" != "$context" ]]; then
    kubectl config rename-context "$source_context" "$context" >/dev/null
  fi
}

prepare_kubeconfig() {
  local contexts

  kubeconfig_candidate="$(mktemp "$runtime_dir/kubeconfig-platform.new.XXXXXX")"
  chmod 600 "$kubeconfig_candidate" 2>/dev/null || true
  printf '%s\n' \
    'apiVersion: v1' 'kind: Config' 'preferences: {}' \
    'clusters: []' 'contexts: []' 'users: []' >"$kubeconfig_candidate"
  set_kubeconfig "$kubeconfig_candidate"
  prepare_context gke-risk-usc1 gke-risk-usc1 us-central1
  prepare_context gke-risk-use4 gke-risk-use4 us-east4
  contexts="$(kubectl config get-contexts -o name | tr -d '\r' | sort)"
  [[ "$contexts" == $'gke-risk-usc1\ngke-risk-use4' ]] \
    || fail "the platform kubeconfig does not contain exactly the two expected contexts"
  mv -f -- "$kubeconfig_candidate" "$kubeconfig"
  kubeconfig_candidate=""
  chmod 600 "$kubeconfig" 2>/dev/null || true
  set_kubeconfig "$kubeconfig"
}

read_current_version() {
  local context="$1" app="$2" namespace deployment selector prefix json
  if [[ "$app" == "app-a" ]]; then
    namespace=currency-app-a
    selector='app=app-a-gateway'
    prefix="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:"
    json="$(kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get deployments --selector="$selector" -o json)" \
      || fail "$context could not read the App A deployment inventory"
    jq -er --arg prefix "$prefix" '
      if (.items | length) == 0 then ""
      else [.items[].spec.template.spec.containers[] | .image
        | select(startswith($prefix)) | ltrimstr($prefix)] | unique
        | if length == 1 and (.[0] | test("^[0-9a-f]{40}$")) then .[0]
          else error("App A has no single immutable version") end
      end
    ' <<<"$json"
  else
    namespace=currency-app-b
    deployment=app-b-engine
    prefix="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:"
    json="$(kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      get deployment "$deployment" --ignore-not-found -o json)" \
      || fail "$context could not read the App B deployment inventory"
    if [[ -z "$json" ]]; then
      printf ''
      return 0
    fi
    jq -er --arg prefix "$prefix" '
      [.spec.template.spec.containers[] | .image
        | select(startswith($prefix)) | ltrimstr($prefix)] | unique
      | if length == 1 and (.[0] | test("^[0-9a-f]{40}$")) then .[0]
        else error("App B has no single immutable version") end
    ' <<<"$json"
  fi
}

delete_bootstrap_workloads() {
  local context region app manifest version
  for spec in 'gke-risk-usc1|us-central1' 'gke-risk-use4|us-east4'; do
    IFS='|' read -r context region <<<"$spec"
    for app in app-a app-b; do
      if [[ "$app" == app-a ]]; then
        version="$app_a_sha"
      else
        version="$app_b_sha"
      fi
      manifest="$work_dir/bootstrap-delete-$region-$app.yaml"
      kubectl kustomize "$repo_root/k8s/overlays/$region/$app" \
        | sed -e "s/PROJECT_ID/$PROJECT_ID/g" \
          -e "s/GIT_SHA/$version/g" \
        >"$manifest"
      kubectl --context="$context" --request-timeout=60s delete -f "$manifest" \
        --ignore-not-found=true --wait=true --timeout=5m >&2 || return 1
    done
  done
}

restore_previous_pair() {
  local restore_a_pid restore_b_pid restore_a_status restore_b_status
  restore_required=0
  if [[ -z "$previous_app_a_sha" && -z "$previous_app_b_sha" ]]; then
    printf 'Coordinated bootstrap failed; deleting both app workloads from both regions.\n' >&2
    delete_bootstrap_workloads
    return
  fi
  [[ "$previous_app_a_sha" =~ ^[0-9a-f]{40}$ \
    && "$previous_app_b_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf 'Coordinated release failed; restoring App A %s / App B %s in both regions.\n' \
    "$previous_app_a_sha" "$previous_app_b_sha" >&2
  DEFER_COMBINED_GATE=1 \
    bash scripts/deploy-app-a.sh "$previous_app_a_sha" "$previous_app_b_sha" >&2 &
  restore_a_pid=$!
  DEFER_COMBINED_GATE=1 \
    bash scripts/deploy-app-b.sh "$previous_app_b_sha" "$previous_app_a_sha" >&2 &
  restore_b_pid=$!
  set +e
  wait "$restore_a_pid"; restore_a_status=$?
  wait "$restore_b_pid"; restore_b_status=$?
  set -e
  ((restore_a_status == 0 && restore_b_status == 0)) \
    && bash scripts/verify-deployment-gates.sh \
      "$previous_app_a_sha" "$previous_app_b_sha"
}

cleanup_platform_apply() {
  local context remaining cleanup_failed=0
  local cleanup_scope="$platform_cleanup_scope"
  platform_cleanup_scope=""
  case "$cleanup_scope" in
    all)
      printf 'Bootstrap platform apply failed; removing only the three newly created namespaces.\n' >&2
      ;;
    observability)
      printf 'Observability expansion failed; removing only the newly created observability namespace.\n' >&2
      ;;
    *) return 1 ;;
  esac
  for context in gke-risk-usc1 gke-risk-use4; do
    if [[ "$cleanup_scope" == all ]]; then
      kubectl --context="$context" --request-timeout=60s \
        delete namespace currency-app-a currency-app-b currency-observability \
        --ignore-not-found=true --wait=true --timeout=10m >&2 \
        || cleanup_failed=1
      remaining="$(kubectl --context="$context" --request-timeout=20s \
        get namespace currency-app-a currency-app-b currency-observability \
          --ignore-not-found -o name)" || cleanup_failed=1
      [[ -z "$remaining" ]] || cleanup_failed=1
    else
      kubectl --context="$context" --request-timeout=60s \
        delete namespace currency-observability \
        --ignore-not-found=true --wait=true --timeout=10m >&2 \
        || cleanup_failed=1
      remaining="$(kubectl --context="$context" --request-timeout=20s \
        get namespace currency-observability --ignore-not-found -o name)" \
        || cleanup_failed=1
      [[ -z "$remaining" ]] || cleanup_failed=1
      remaining="$(kubectl --context="$context" --request-timeout=20s \
        get namespace currency-app-a currency-app-b -o name | tr -d '\r' | sort)" \
        || cleanup_failed=1
      [[ "$remaining" == $'namespace/currency-app-a\nnamespace/currency-app-b' ]] \
        || cleanup_failed=1
      kubectl --context="$context" --namespace=currency-app-a --request-timeout=20s \
        get service app-a-gateway -o name >/dev/null || cleanup_failed=1
      kubectl --context="$context" --namespace=currency-app-b --request-timeout=20s \
        get service app-b-engine -o name >/dev/null || cleanup_failed=1
    fi
  done
  ((cleanup_failed == 0))
}

render_platform() {
  local region="$1"
  local output="$2"

  kubectl kustomize "$repo_root/k8s/overlays/$region/platform" \
    | sed -e "s/PROJECT_ID/$PROJECT_ID/g" >"$output"
  ! grep -Eq \
    '(^|[^A-Z0-9_])PROJECT_ID([^A-Z0-9_]|$)|(^|[^A-Z0-9_])GIT_SHA([^A-Z0-9_]|$)|:latest([[:space:]]|$)' \
    "$output" || fail "$region platform render contains a placeholder or latest tag"
  ! grep -Eq '^kind: (Deployment|HorizontalPodAutoscaler|Job|PodDisruptionBudget)$' "$output" \
    || fail "$region platform render contains a team-owned workload resource"
  [[ "$(grep -Ec '^kind: Namespace$' "$output")" == "3" ]] \
    && grep -Fq -- 'name: currency-app-a' "$output" \
    && grep -Fq -- 'name: currency-app-b' "$output" \
    && grep -Fq -- 'name: currency-observability' "$output" \
    || fail "$region platform render does not declare both team namespaces and the observability namespace"
  [[ "$(grep -Ec '^kind: Service$' "$output")" == "2" ]] \
    && [[ "$(grep -Ec '^kind: ServiceAccount$' "$output")" == "3" ]] \
    && [[ "$(grep -Ec '^kind: Role$' "$output")" == "2" ]] \
    && [[ "$(grep -Ec '^kind: RoleBinding$' "$output")" == "2" ]] \
    && [[ "$(grep -Ec '^kind: ResourceQuota$' "$output")" == "3" ]] \
    && [[ "$(grep -Ec '^kind: NetworkPolicy$' "$output")" -ge "2" ]] \
    || fail "$region platform render is missing an ownership or isolation control"
  for mode in enforce audit warn; do
    [[ "$(grep -Fc -- "pod-security.kubernetes.io/$mode: restricted" "$output")" == "3" ]] \
      || fail "$region platform render is missing restricted Pod Security $mode labels"
  done
  grep -Fq -- "currency-app-a-deployer@$PROJECT_ID.iam.gserviceaccount.com" "$output" \
    && grep -Fq -- "currency-app-b-deployer@$PROJECT_ID.iam.gserviceaccount.com" "$output" \
    || fail "$region platform render is missing one deployer RoleBinding subject"
  ! grep -Eq 'application-developer|currency-app-(a|b)-dev@' "$output" \
    || fail "$region platform render grants a developer production access"
}

verify_platform_cutover_state() {
  local context namespace namespace_name service_name
  local team_namespace_count=0 observability_namespace_count=0
  local app_a_service_count=0 app_b_service_count=0
  local neg_inventory backend_inventory cutover_mode
  for context in gke-risk-usc1 gke-risk-use4; do
    kubectl --context="$context" --request-timeout=20s \
      get namespace default -o name >/dev/null \
      || fail "$context Kubernetes API is unavailable; refusing to infer resource absence"
    namespace_name="$(kubectl --context="$context" --request-timeout=20s \
      get namespace risk-system --ignore-not-found -o name)" \
      || fail "$context could not prove that the legacy risk-system namespace is absent"
    [[ -z "$namespace_name" ]] \
      || fail "$context still contains the legacy risk-system namespace; finish the authorized cutover first"

    for namespace in currency-app-a currency-app-b; do
      namespace_name="$(kubectl --context="$context" --request-timeout=20s \
        get namespace "$namespace" --ignore-not-found -o name)" \
        || fail "$context could not read namespace $namespace"
      if [[ "$namespace_name" == "namespace/$namespace" ]]; then
        team_namespace_count=$((team_namespace_count + 1))
      elif [[ -n "$namespace_name" ]]; then
        fail "$context returned an unexpected identity for namespace $namespace"
      fi
    done
    namespace_name="$(kubectl --context="$context" --request-timeout=20s \
      get namespace currency-observability --ignore-not-found -o name)" \
      || fail "$context could not read namespace currency-observability"
    if [[ "$namespace_name" == "namespace/currency-observability" ]]; then
      observability_namespace_count=$((observability_namespace_count + 1))
    elif [[ -n "$namespace_name" ]]; then
      fail "$context returned an unexpected observability namespace identity"
    fi

    namespace_name="$(kubectl --context="$context" --request-timeout=20s \
      get namespace currency-app-a --ignore-not-found -o name)" \
      || fail "$context could not read namespace currency-app-a"
    if [[ -n "$namespace_name" ]]; then
      service_name="$(kubectl --context="$context" --namespace=currency-app-a \
        --request-timeout=20s get service app-a-gateway --ignore-not-found -o name)" \
        || fail "$context could not read the new App A Service inventory"
      [[ -z "$service_name" || "$service_name" == "service/app-a-gateway" ]] \
        || fail "$context returned an unexpected App A Service identity"
      if [[ -n "$service_name" ]]; then
        app_a_service_count=$((app_a_service_count + 1))
      fi
    fi

    namespace_name="$(kubectl --context="$context" --request-timeout=20s \
      get namespace currency-app-b --ignore-not-found -o name)" \
      || fail "$context could not read namespace currency-app-b"
    if [[ -n "$namespace_name" ]]; then
      service_name="$(kubectl --context="$context" --namespace=currency-app-b \
        --request-timeout=20s get service app-b-engine --ignore-not-found -o name)" \
        || fail "$context could not read the App B Service inventory"
      [[ -z "$service_name" || "$service_name" == "service/app-b-engine" ]] \
        || fail "$context returned an unexpected App B Service identity"
      if [[ -n "$service_name" ]]; then
        app_b_service_count=$((app_b_service_count + 1))
      fi
    fi
  done
  cutover_mode="$(classify_platform_inventory \
    "$team_namespace_count" "$observability_namespace_count" \
    "$app_a_service_count" "$app_b_service_count")" \
    || fail "regional platform inventory is partial or asymmetric"
  if [[ "$cutover_mode" == bootstrap ]]; then
    platform_absent=1

    neg_inventory="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      compute network-endpoint-groups list --format=json)" \
      || fail "could not prove that the six old named NEGs are absent"
    jq -e '[.[] | select(.name == "app-a-neg-usc1" or .name == "app-a-neg-use4")] | length == 0' \
      <<<"$neg_inventory" >/dev/null \
      || fail "bootstrap requires all six old named NEGs to be garbage-collected before new Services are created"

    backend_inventory="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      compute backend-services list --global --format=json)" \
      || fail "could not prove that the old load-balancer backend is absent or detached"
    jq -e '
      [.[] | select(.name == "risk-app-a-gateway-backend")] as $matches |
      ($matches | length) <= 1 and
      all($matches[]; ((.backends // []) | length) == 0)
    ' <<<"$backend_inventory" >/dev/null \
      || fail "bootstrap requires the old backend service to be absent or detached from all NEGs"
    return 0
  fi
  if [[ "$cutover_mode" == expansion ]]; then
    platform_expansion=1
  fi
  # Either the symmetric established two-team platform or the fully expanded
  # platform is safe. One-cell observability state was rejected above.
}

prepare_kubeconfig
work_dir="$(mktemp -d "$runtime_dir/deploy-apps.XXXXXX")"
render_platform us-central1 "$work_dir/platform-us-central1.yaml"
render_platform us-east4 "$work_dir/platform-us-east4.yaml"
bash scripts/verify-kustomize-contracts.sh
verify_platform_cutover_state
if ((platform_absent == 1)); then
  central_app_a=""
  east_app_a=""
  central_app_b=""
  east_app_b=""
else
  central_app_a="$(read_current_version gke-risk-usc1 app-a)"
  east_app_a="$(read_current_version gke-risk-use4 app-a)"
  central_app_b="$(read_current_version gke-risk-usc1 app-b)"
  east_app_b="$(read_current_version gke-risk-use4 app-b)"
fi
[[ "$central_app_a" == "$east_app_a" && "$central_app_b" == "$east_app_b" ]] \
  || fail "the existing app versions are inconsistent across regions"
[[ -n "$central_app_a" && -n "$central_app_b" ]] \
  || [[ -z "$central_app_a" && -z "$central_app_b" ]] \
  || fail "bootstrap requires both apps to be absent; an update requires both apps to exist"
previous_app_a_sha="$central_app_a"
previous_app_b_sha="$central_app_b"
if [[ -z "$previous_app_a_sha" && -z "$previous_app_b_sha" ]]; then
  bootstrap_mode=1
fi
if ((platform_absent == 1)); then
  platform_cleanup_scope=all
elif ((platform_expansion == 1)); then
  platform_cleanup_scope=observability
fi
kubectl --context=gke-risk-usc1 --request-timeout=60s \
  apply -f "$work_dir/platform-us-central1.yaml" \
  >"$work_dir/platform-us-central1.log" 2>&1 &
platform_central_pid=$!
kubectl --context=gke-risk-use4 --request-timeout=60s \
  apply -f "$work_dir/platform-us-east4.yaml" \
  >"$work_dir/platform-us-east4.log" 2>&1 &
platform_east_pid=$!
set +e
wait "$platform_central_pid"; platform_central_status=$?; platform_central_pid=""
wait "$platform_east_pid"; platform_east_status=$?; platform_east_pid=""
set -e
cat "$work_dir/platform-us-central1.log"
cat "$work_dir/platform-us-east4.log"
((platform_central_status == 0 && platform_east_status == 0)) \
  || fail "one or both regional platform applies failed"
platform_cleanup_scope=""

# The app lanes have distinct namespaces, RBAC identities, kubeconfigs, and
# work directories. They can therefore reconcile the shared clusters safely in
# parallel; the final combined gate is authoritative for the requested pair.
restore_required=1
DEFER_COMBINED_GATE=1 bash scripts/deploy-app-a.sh "$app_a_sha" "$app_b_sha" \
  >"$work_dir/app-a.log" 2>&1 &
app_a_pid=$!
DEFER_COMBINED_GATE=1 bash scripts/deploy-app-b.sh "$app_b_sha" "$app_a_sha" \
  >"$work_dir/app-b.log" 2>&1 &
app_b_pid=$!

set +e
wait "$app_a_pid"
app_a_status=$?
app_a_pid=""
wait "$app_b_pid"
app_b_status=$?
app_b_pid=""
set -e

cat "$work_dir/app-a.log"
cat "$work_dir/app-b.log"
((app_a_status == 0)) || fail "App A deployment lane failed"
((app_b_status == 0)) || fail "App B deployment lane failed"

if ((bootstrap_mode == 1)); then
  bash scripts/verify-deployment-gates.sh --pre-edge "$app_a_sha" "$app_b_sha"
  restore_required=0
  printf 'Bootstrapped and pre-edge verified App A %s / App B %s in both regional cells.\n' \
    "$app_a_sha" "$app_b_sha"
  printf 'Next: Ops applies the 30-lb Terraform stack, then runs: bash scripts/verify-deployment-gates.sh %s %s\n' \
    "$app_a_sha" "$app_b_sha"
  exit 0
fi
bash scripts/verify-deployment-gates.sh "$app_a_sha" "$app_b_sha"
restore_required=0
printf 'Applied and verified App A %s / App B %s in both regional cells.\n' \
  "$app_a_sha" "$app_b_sha"

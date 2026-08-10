#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
runtime_dir="$repo_root/.tmp"
kubeconfig="$runtime_dir/kubeconfig-schwab-assessment"
kubeconfig_candidate=""
work_dir=""

fail() {
  printf 'deploy-apps: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/deploy-apps.*)
        rm -f -- "$work_dir"/*.yaml
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

for command_name in gcloud git jq kubectl sed terraform timeout; do
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

# This is the hard boundary between image publication and workload mutation.
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

render_overlay() {
  local region="$1"
  local overlay="$repo_root/k8s/overlays/$region"
  local rendered="$work_dir/$region.yaml"
  local app_a_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a:$git_sha"
  local app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$git_sha"
  local auth_audience="https://app-b-engine.schwab-assessment.internal"
  local caller_email="currency-app-a-caller@$PROJECT_ID.iam.gserviceaccount.com"

  kubectl kustomize "$overlay" \
    | sed -e "s/PROJECT_ID/$PROJECT_ID/g" -e "s/GIT_SHA/$git_sha/g" \
    >"$rendered"

  if grep -Eq \
    '(^|[^A-Z0-9_])PROJECT_ID([^A-Z0-9_]|$)|(^|[^A-Z0-9_])GIT_SHA([^A-Z0-9_]|$)|app-a-image|app-b-image|:latest([[:space:]]|$)' \
    "$rendered"; then
    fail "$region render still contains an image placeholder or forbidden latest tag"
  fi
  [[ "$(grep -Fc -- "image: $app_a_image" "$rendered")" == "3" ]] \
    || fail "$region render does not contain exactly three expected App A images"
  [[ "$(grep -Fc -- "image: $app_b_image" "$rendered")" == "1" ]] \
    || fail "$region render does not contain exactly one expected App B image"
  [[ "$(grep -Fc -- 'name: APP_B_AUTH_MODE' "$rendered")" == "4" ]] \
    && [[ "$(grep -Fc -- 'value: google-id-token' "$rendered")" == "4" ]] \
    && [[ "$(grep -Fc -- 'name: APP_B_TOKEN_AUDIENCE' "$rendered")" == "4" ]] \
    && [[ "$(grep -Fc -- "value: $auth_audience" "$rendered")" == "4" ]] \
    || fail "$region render does not require Google ID-token authentication for both apps"
  [[ "$(grep -Fc -- 'name: GOOGLE_CLOUD_PROJECT' "$rendered")" == "4" ]] \
    && [[ "$(grep -Fc -- "value: $PROJECT_ID" "$rendered")" == "4" ]] \
    || fail "$region render does not bind both apps to the deployment project"
  [[ "$(grep -Fc -- "iam.gke.io/gcp-service-account: $caller_email" "$rendered")" == "1" ]] \
    && [[ "$(grep -Fc -- "value: $caller_email" "$rendered")" == "1" ]] \
    || fail "$region render does not bind and verify the exact App A caller identity"
  ! grep -Fq -- 'value: disabled' "$rendered" \
    || fail "$region deployed render must never disable App B authentication"
}

prepare_kubeconfig
work_dir="$(mktemp -d "$runtime_dir/deploy-apps.XXXXXX")"
render_overlay us-central1
render_overlay us-east4

kubectl --context=gke-risk-usc1 --request-timeout=60s \
  apply -f "$work_dir/us-central1.yaml"
kubectl --context=gke-risk-use4 --request-timeout=60s \
  apply -f "$work_dir/us-east4.yaml"

# The first rollout used one shared App A Deployment/HPA. Remove only those
# exact superseded controllers after the three zonal shards are declared.
for context in gke-risk-usc1 gke-risk-use4; do
  kubectl --context="$context" --namespace=risk-system --request-timeout=60s \
    delete deployment/app-a-gateway horizontalpodautoscaler/app-a-gateway \
    --ignore-not-found=true --wait=true --timeout=2m
done

bash scripts/verify-workloads.sh "$git_sha"
printf 'Applied and verified both regional workload cells at %s.\n' "$git_sha"

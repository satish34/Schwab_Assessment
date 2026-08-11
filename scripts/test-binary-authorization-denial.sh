#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "${ENABLE_BINARY_AUTHORIZATION:-0}" == "1" ]] || {
  printf '%s\n' \
    'Binary Authorization is implemented but disabled; no denial request will be sent.' >&2
  exit 2
}

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
cluster_name="gke-risk-usc1"
cluster_location="us-central1"
namespace="currency-app-b"
pod_name="binauthz-denial-proof"
image="docker.io/library/nginx:1.27.5"
context="gke-risk-usc1"
runtime_dir="$repo_root/.tmp"
kubeconfig_candidate=""
cleanup_pod=false
pod_overrides='{"apiVersion":"v1","spec":{"securityContext":{"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"binauthz-denial-proof","image":"docker.io/library/nginx:1.27.5","resources":{"requests":{"cpu":"250m","memory":"512Mi","ephemeral-storage":"1Gi"},"limits":{"cpu":"500m","memory":"768Mi","ephemeral-storage":"1Gi"}},"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true}}]}}'

fail() {
  printf 'test-binary-authorization-denial: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ "$cleanup_pod" == true && -n "$kubeconfig_candidate" ]]; then
    kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
      delete pod "$pod_name" --ignore-not-found --wait=true --timeout=45s \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$kubeconfig_candidate" && -f "$kubeconfig_candidate" ]]; then
    rm -f -- "$kubeconfig_candidate"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"

for command_name in gcloud grep kubectl mktemp timeout tr; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected gcloud account $expected_account"

configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected configured project $PROJECT_ID"

bash "$repo_root/scripts/verify-binary-authorization.sh"

bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"
mkdir -p "$runtime_dir"
kubeconfig_candidate="$(mktemp "$runtime_dir/binauthz-kubeconfig.XXXXXX")"
chmod 600 "$kubeconfig_candidate" 2>/dev/null || true
printf '%s\n' \
  'apiVersion: v1' \
  'kind: Config' \
  'preferences: {}' \
  'clusters: []' \
  'contexts: []' \
  'users: []' >"$kubeconfig_candidate"
case "$(uname -s)" in
  MINGW*|MSYS*) KUBECONFIG="$(cygpath -w "$kubeconfig_candidate")" ;;
  *) KUBECONFIG="$kubeconfig_candidate" ;;
esac
export KUBECONFIG

timeout --foreground --signal=INT 2m \
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
  --account="$expected_account" \
  --project="$PROJECT_ID" \
  container clusters get-credentials "$cluster_name" \
  --region="$cluster_location"
source_context="$(kubectl config current-context | tr -d '\r')"
[[ -n "$source_context" ]] || fail "gcloud did not create a cluster context"
if [[ "$source_context" != "$context" ]]; then
  kubectl config rename-context "$source_context" "$context" >/dev/null
fi

MSYS_NO_PATHCONV=1 kubectl --context="$context" --request-timeout=15s \
  get --raw=/version >/dev/null

assert_pod_absent() {
  if kubectl --context="$context" --namespace="$namespace" --request-timeout=20s \
    get pod "$pod_name" >/dev/null 2>&1; then
    fail "unexpected Pod $namespace/$pod_name exists"
  fi
}

assert_pod_absent

cleanup_pod=true
set +e
denial_output="$(
  kubectl --context="$context" --namespace="$namespace" run "$pod_name" \
    --image="$image" \
    --restart=Never \
    --overrides="$pod_overrides" \
    --request-timeout=30s \
    --output=yaml 2>&1
)"
denial_status=$?
set -e

if ((denial_status == 0)); then
  fail "the live create request unexpectedly admitted $image; cleanup was requested"
fi

if ! grep -Eiq \
  'denied by Binary Authorization|Binary Authorization.*denied|imagepolicywebhook\.image-policy\.k8s\.io.*denied' \
  <<<"$denial_output"; then
  printf 'The live create request failed, but not with a Binary Authorization denial:\n%s\n' \
    "$denial_output" >&2
  exit 1
fi

assert_pod_absent
cleanup_pod=false

printf 'Image: %s\n' "$image"
printf 'Mode: live Pod create request (denied; nothing persisted)\n'
printf 'Result: denied by Binary Authorization\n'
printf '%s\n' "$denial_output"

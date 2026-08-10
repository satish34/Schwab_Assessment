#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_project_number="458160069040"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
expected_confirmation="destroy-schwab-assessment-gke-keep-project"
namespace="risk-system"
runtime_root="$repo_root/.tmp"
evidence_file="$repo_root/evidence/13-teardown.txt"
neg_timeout_seconds="${NEG_GC_TIMEOUT_SECONDS:-1200}"
work_dir=""
existing_cells=()

fail() {
  printf 'destroy: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_root"/destroy.*) rm -rf -- "$work_dir" ;;
    esac
  fi
}
trap cleanup EXIT

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${BILLING_ACCOUNT_ID:?BILLING_ACCOUNT_ID is required}"
: "${ADMIN_CIDR:?ADMIN_CIDR is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "${DESTROY_CONFIRMATION:-}" == "$expected_confirmation" ]] || {
  printf 'Refusing teardown. Set exactly:\n' >&2
  printf 'DESTROY_CONFIRMATION=%s\n' "$expected_confirmation" >&2
  exit 2
}
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"
[[ "$neg_timeout_seconds" =~ ^[0-9]+$ ]] \
  && ((neg_timeout_seconds >= 300 && neg_timeout_seconds <= 1800)) \
  || fail "NEG_GC_TIMEOUT_SECONDS must be between 300 and 1800"

for command_name in gcloud git jq kubectl terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] || fail "$override_name must be unset"
done

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"
for auth_property in \
  auth/access_token_file auth/credential_file_override \
  auth/impersonate_service_account; do
  auth_value="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value "$auth_property" 2>/dev/null)"
  [[ -z "$auth_value" || "$auth_value" == "(unset)" ]] \
    || fail "$auth_property must be unset in the named gcloud configuration"
done
project_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" projects describe "$PROJECT_ID" --format=json
)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "named gcloud configuration targets ${configured_project:-<none>}"
jq -e --arg id "$expected_project" --arg number "$expected_project_number" '
  .projectId == $id and (.projectNumber | tostring) == $number and
  .name == "Schwab Assessment" and .lifecycleState == "ACTIVE"
' <<<"$project_json" >/dev/null \
  || fail "the live project identity does not match the dedicated assessment project"

terraform -chdir=infra/10-global state show google_project.current 2>/dev/null \
  | grep -F 'deletion_policy = "ABANDON"' >/dev/null \
  || fail "10-global state does not guarantee project abandonment"

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"

mkdir -p "$runtime_root" "$repo_root/evidence"
work_dir="$(mktemp -d "$runtime_root/destroy.XXXXXX")"
git check-ignore --quiet -- "$work_dir" \
  || fail "the destroy runtime directory must stay ignored"
rm -f -- "$evidence_file"
transcript_candidate="$work_dir/13-teardown.txt"

prepare_kubeconfig() {
  local kubeconfig_posix="$work_dir/kubeconfig"
  local context cluster region spec
  local contexts expected_contexts
  local source_context

  : >"$kubeconfig_posix"
  case "$(uname -s)" in
    MINGW*|MSYS*) KUBECONFIG="$(cygpath -w "$kubeconfig_posix")" ;;
    *) KUBECONFIG="$kubeconfig_posix" ;;
  esac
  export KUBECONFIG

  for spec in "${existing_cells[@]}"; do
    IFS='|' read -r context cluster region <<<"$spec"
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      container clusters get-credentials "$cluster" --region="$region"
    source_context="$(kubectl config current-context | tr -d '\r')"
    [[ "$source_context" == "$context" ]] \
      || kubectl config rename-context "$source_context" "$context" >/dev/null
  done

  contexts="$(kubectl config get-contexts -o name | tr -d '\r' | sort)"
  expected_contexts="$(
    printf '%s\n' "${existing_cells[@]}" | cut -d'|' -f1 | sort
  )"
  [[ "$contexts" == "$expected_contexts" ]] \
    || fail "the teardown kubeconfig does not match the existing frozen cells"
}

discover_existing_cells() {
  local clusters_json context cluster region spec
  local expected_cells=(
    'gke-risk-usc1|gke-risk-usc1|us-central1'
    'gke-risk-use4|gke-risk-use4|us-east4'
  )

  clusters_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      container clusters list --format=json
  )"
  existing_cells=()
  for spec in "${expected_cells[@]}"; do
    IFS='|' read -r context cluster region <<<"$spec"
    if jq -e --arg name "$cluster" --arg location "$region" '
      any(.[]; .name == $name and .location == $location)
    ' <<<"$clusters_json" >/dev/null; then
      existing_cells+=("$spec")
    else
      printf 'Expected cell already absent: %s (%s).\n' "$cluster" "$region"
    fi
  done
}

wait_for_neg_gc() {
  local deadline=$((SECONDS + neg_timeout_seconds))
  local remaining

  while ((SECONDS < deadline)); do
    remaining="$(
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
        --account="$expected_account" --project="$PROJECT_ID" \
        compute network-endpoint-groups list \
        --format='value(name,zone)' \
        | grep -E '^app-a-neg-(usc1|use4)([[:space:]]|$)' || true
    )"
    if [[ -z "$remaining" ]]; then
      printf 'All six App A NEGs were garbage-collected.\n'
      return 0
    fi
    printf 'Waiting for GKE NEG garbage collection: %s\n' \
      "$(tr '\n' ';' <<<"$remaining")"
    sleep 15
  done
  return 1
}

perform_destroy() {
  printf 'Ordered teardown started for %s; project will be retained.\n' "$PROJECT_ID"
  TF_AUTO_APPROVE=1 bash "$repo_root/scripts/terraform-stack.sh" \
    infra/30-lb destroy

  discover_existing_cells
  if ((${#existing_cells[@]} > 0)); then
    bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"
    prepare_kubeconfig
    for spec in "${existing_cells[@]}"; do
      IFS='|' read -r context cluster region <<<"$spec"
      timeout --foreground --signal=INT --kill-after=10s 2m \
        kubectl --context="$context" --namespace="$namespace" \
          --request-timeout=30s delete service app-a-gateway \
          --ignore-not-found --wait=true
    done
  else
    printf 'Both expected GKE cells are already absent; skipping Service deletion.\n'
  fi
  wait_for_neg_gc \
    || fail "App A NEGs did not disappear before cluster teardown"

  TF_AUTO_APPROVE=1 bash "$repo_root/scripts/terraform-stack.sh" \
    infra/20-cluster destroy
  TF_AUTO_APPROVE=1 bash "$repo_root/scripts/terraform-stack.sh" \
    infra/10-global destroy
  TF_AUTO_APPROVE=1 bash "$repo_root/scripts/terraform-stack.sh" \
    infra/00-bootstrap destroy

  bash "$repo_root/scripts/orphan-check.sh"
  retained_state="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" projects describe "$PROJECT_ID" \
      --format='value(lifecycleState)'
  )"
  [[ "$retained_state" == "ACTIVE" ]] || fail "the retained project is not ACTIVE"
  printf 'Teardown gate: PASS\nproject_retained=true\n'
}

set +e
(
  set -Eeuo pipefail
  perform_destroy
) 2>&1 | tee "$transcript_candidate"
destroy_code=${PIPESTATUS[0]}
set -e
((destroy_code == 0)) || exit "$destroy_code"

mv -f -- "$transcript_candidate" "$evidence_file"
printf 'Teardown evidence: evidence/13-teardown.txt\n'

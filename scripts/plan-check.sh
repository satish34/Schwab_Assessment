#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
evidence_file="$repo_root/evidence/12-plan-check.txt"
runtime_dir="$repo_root/.tmp/plan-check"
terraform_timeout="${TERRAFORM_TIMEOUT:-20m}"
stacks=(infra/00-bootstrap infra/10-global infra/20-cluster infra/30-lb)

fail() {
  printf 'plan-check: %s\n' "$*" >&2
  exit 1
}

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${BILLING_ACCOUNT_ID:?BILLING_ACCOUNT_ID is required}"
: "${ADMIN_CIDR:?ADMIN_CIDR is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

enable_cloud_armor="${ENABLE_CLOUD_ARMOR:-0}"
enable_binary_authorization="${ENABLE_BINARY_AUTHORIZATION:-0}"
for feature_flag in enable_cloud_armor enable_binary_authorization; do
  feature_value="${!feature_flag}"
  [[ "$feature_value" == "0" || "$feature_value" == "1" ]] \
    || fail "${feature_flag^^} must be 0 or 1"
done

[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"
[[ "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] \
  || fail "ADMIN_CIDR must be an explicit IPv4 /32"

for command_name in gcloud git jq terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] \
    || fail "$override_name must be unset"
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
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "named gcloud configuration targets ${configured_project:-<none>}"

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export TF_VAR_project_id="$PROJECT_ID"
export TF_VAR_billing_account_id="$BILLING_ACCOUNT_ID"
export TF_VAR_gcloud_configuration="$GCLOUD_CONFIGURATION"
export TF_VAR_admin_cidr="$ADMIN_CIDR"
export TF_VAR_domain_name="${DOMAIN_NAME:-}"
export TF_VAR_enable_cloud_armor=false
export TF_VAR_enable_binary_authorization=false
[[ "$enable_cloud_armor" == "1" ]] && export TF_VAR_enable_cloud_armor=true
[[ "$enable_binary_authorization" == "1" ]] && export TF_VAR_enable_binary_authorization=true
trap 'unset GOOGLE_OAUTH_ACCESS_TOKEN TF_VAR_project_id TF_VAR_billing_account_id TF_VAR_gcloud_configuration TF_VAR_admin_cidr TF_VAR_domain_name TF_VAR_enable_cloud_armor TF_VAR_enable_binary_authorization' EXIT

mkdir -p "$runtime_dir" "$repo_root/evidence"
git check-ignore --quiet -- "$runtime_dir" \
  || fail "the plan-check runtime directory must stay ignored"
rm -f -- "$evidence_file"
summary_candidate="$runtime_dir/12-plan-check.txt"
printf 'Terraform drift gate\nproject=%s\n' \
  "$PROJECT_ID" >"$summary_candidate"

GOOGLE_OAUTH_ACCESS_TOKEN="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      auth print-access-token
)"
export GOOGLE_OAUTH_ACCESS_TOKEN

overall=0
for stack in "${stacks[@]}"; do
  stack_name="${stack#infra/}"
  init_log="$runtime_dir/$stack_name-init.txt"
  plan_log="$runtime_dir/$stack_name-plan.txt"

  timeout --foreground --signal=INT --kill-after=15s "$terraform_timeout" \
    terraform -chdir="$stack" init -input=false -no-color \
    >"$init_log" 2>&1 \
    || {
      command cat -- "$init_log" >&2
      fail "$stack initialization failed"
    }

  set +e
  timeout --foreground --signal=INT --kill-after=15s "$terraform_timeout" \
    terraform -chdir="$stack" plan -input=false -no-color \
      -detailed-exitcode >"$plan_log" 2>&1
  plan_code=$?
  set -e

  case "$plan_code" in
    0)
      status="NO_CHANGES"
      ;;
    2)
      status="DRIFT"
      overall=1
      ;;
    *)
      command cat -- "$plan_log" >&2
      fail "$stack plan failed with exit code $plan_code"
      ;;
  esac

  plan_line="$(
    grep -E '^(No changes\.|Plan:)' "$plan_log" | tail -n 1 || true
  )"
  [[ -n "$plan_line" ]] || plan_line="Terraform returned detailed exit code $plan_code"
  printf 'stack=%s status=%s summary=%s\n' \
    "$stack_name" "$status" "$plan_line" >>"$summary_candidate"
done

((overall == 0)) || fail "one or more Terraform stacks contain drift"
printf 'overall=PASS\n' >>"$summary_candidate"
mv -f -- "$summary_candidate" "$evidence_file"
command cat -- "$evidence_file"

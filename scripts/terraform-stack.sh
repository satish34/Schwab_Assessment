#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s STACK_DIR plan|apply|destroy\n' "$0" >&2
  exit 2
fi

stack_dir="$1"
action="$2"
expected_account="satish.cse7@gmail.com"

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${BILLING_ACCOUNT_ID:?BILLING_ACCOUNT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

case "$action" in
  plan|apply|destroy) ;;
  *)
    printf 'Unsupported Terraform action: %s\n' "$action" >&2
    exit 2
    ;;
esac

[[ -d "$stack_dir" ]] || {
  printf 'Terraform stack not found: %s\n' "$stack_dir" >&2
  exit 1
}

if [[ "$stack_dir" != "infra/00-bootstrap" ]]; then
  printf 'This short-lived-token wrapper is limited to infra/00-bootstrap.\n' >&2
  exit 2
fi

active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
if [[ "$active_account" != "$expected_account" ]]; then
  printf 'Expected gcloud account %s, found %s.\n' "$expected_account" "${active_account:-<none>}" >&2
  exit 1
fi

configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
if [[ "$configured_project" != "$PROJECT_ID" ]]; then
  printf 'Expected gcloud project %s, found %s.\n' "$PROJECT_ID" "${configured_project:-<none>}" >&2
  exit 1
fi

GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud --configuration="$GCLOUD_CONFIGURATION" auth print-access-token)"
export GOOGLE_OAUTH_ACCESS_TOKEN
trap 'unset GOOGLE_OAUTH_ACCESS_TOKEN' EXIT

common_args=(
  -input=false
  -var="project_id=$PROJECT_ID"
  -var="billing_account_id=$BILLING_ACCOUNT_ID"
)

terraform -chdir="$stack_dir" init -input=false

if [[ "$action" == "plan" ]]; then
  terraform -chdir="$stack_dir" plan "${common_args[@]}"
  exit 0
fi

approve_args=()
if [[ "${TF_AUTO_APPROVE:-0}" == "1" ]]; then
  approve_args=(-auto-approve)
fi

terraform -chdir="$stack_dir" "$action" "${common_args[@]}" "${approve_args[@]}"

if [[ "$action" == "apply" && "$stack_dir" == "infra/00-bootstrap" ]]; then
  project_number="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" projects describe "$PROJECT_ID" \
      --format='value(projectNumber)'
  )"
  [[ "$project_number" =~ ^[0-9]+$ ]] || {
    printf 'Could not resolve the numeric project ID for budget verification.\n' >&2
    exit 1
  }

  budgets_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" billing budgets list \
      --billing-account="$BILLING_ACCOUNT_ID" \
      --format=json
  )"

  jq -e \
    --arg display_name 'Schwab Assessment - 30 USD Safety Budget' \
    --arg project "projects/$project_number" \
    '
      [.[] | select(.displayName == $display_name)] as $matches
      | (($matches | length) == 1)
        and ($matches[0].budgetFilter.projects == [$project])
        and ($matches[0].amount.specifiedAmount.currencyCode == "USD")
        and (($matches[0].amount.specifiedAmount.units | tonumber) == 30)
        and (($matches[0].amount.specifiedAmount.nanos // 0) == 0)
        and (
          [$matches[0].thresholdRules[]
            | select(.spendBasis == "CURRENT_SPEND")
            | .thresholdPercent]
          | sort
          == [0.5, 0.8, 0.9, 1]
        )
    ' <<<"$budgets_json" >/dev/null || {
      printf 'The project budget does not match the frozen 30 USD contract.\n' >&2
      exit 1
    }

  printf 'Verified project-scoped 30 USD budget and four current-spend thresholds.\n'
fi

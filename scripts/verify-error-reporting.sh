#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"

fail() {
  printf 'verify-error-reporting: %s\n' "$*" >&2
  exit 1
}

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"

for command_name in curl gcloud jq timeout; do
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
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value account 2>/dev/null
)"
configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value project 2>/dev/null
)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "named configuration targets ${configured_project:-<none>}"

enabled="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" --project="$PROJECT_ID" \
    services list --enabled \
    --filter='name:clouderrorreporting.googleapis.com' \
    --format='value(name)'
)"
[[ "$enabled" == */clouderrorreporting.googleapis.com ]] \
  || fail "Cloud Error Reporting API is not enabled"

access_token="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      auth print-access-token
)"
trap 'unset access_token' EXIT

response="$(
  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    | curl --config - --silent --show-error --fail-with-body --max-time 30 \
      "https://clouderrorreporting.googleapis.com/v1beta1/projects/$PROJECT_ID/groupStats?timeRange.period=PERIOD_1_WEEK&pageSize=100"
)"

total_groups="$(jq -r '[.errorGroupStats[]?] | length' <<<"$response")"
app_b_count="$(
  jq -r '[
    .errorGroupStats[]?
    | select(
        (.representative.message // "")
        | startswith("AppB.InjectedExchangeRateFaultException:")
      )
    | (.count | tonumber)
  ] | add // 0' <<<"$response"
)"
app_a_count="$(
  jq -r '[
    .errorGroupStats[]?
    | select(
        (.representative.message // "")
        | contains("com.schwab.exchange.gateway.client.DependencyUnavailableException")
      )
    | (.count | tonumber)
  ] | add // 0' <<<"$response"
)"

((total_groups >= 2)) || fail "fewer than two error groups were returned"
((app_b_count > 0)) || fail "the controlled App B error group is absent"
((app_a_count > 0)) || fail "the controlled App A error group is absent"

printf 'Error Reporting gate\n'
printf 'project=%s\n' "$PROJECT_ID"
printf 'period=PERIOD_1_WEEK\n'
printf 'total_groups=%s\n' "$total_groups"
printf 'app_b_injected_fault_occurrences=%s\n' "$app_b_count"
printf 'app_a_dependency_failure_occurrences=%s\n' "$app_a_count"
printf 'overall=PASS\n'

#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
stacks=(infra/00-bootstrap infra/10-global infra/20-cluster infra/30-lb)
orphan_count=0

fail() {
  printf 'orphan-check: %s\n' "$*" >&2
  exit 1
}

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"

for command_name in curl gcloud jq terraform timeout; do
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
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "named gcloud configuration targets ${configured_project:-<none>}"

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

gcloud_scoped() {
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" --project="$PROJECT_ID" "$@"
}

record_names() {
  local label="$1"
  local names="$2"
  local count

  names="$(tr -d '\r' <<<"$names" | sed '/^[[:space:]]*$/d')"
  if [[ -z "$names" ]]; then
    printf '%s=0\n' "$label"
    return
  fi
  count="$(wc -l <<<"$names" | tr -d ' ')"
  orphan_count=$((orphan_count + count))
  printf '%s=%s [%s]\n' "$label" "$count" "$(paste -sd, <<<"$names")"
}

report_transient_names() {
  local label="$1"
  local names="$2"
  local count

  names="$(tr -d '\r' <<<"$names" | sed '/^[[:space:]]*$/d')"
  if [[ -z "$names" ]]; then
    printf '%s=0\n' "$label"
    return
  fi
  count="$(wc -l <<<"$names" | tr -d ' ')"
  printf '%s=%s [%s] transient_non_orphan=true\n' \
    "$label" "$count" "$(paste -sd, <<<"$names")"
}

report_retained_names() {
  local label="$1"
  local names="$2"
  local count

  names="$(tr -d '\r' <<<"$names" | sed '/^[[:space:]]*$/d')"
  if [[ -z "$names" ]]; then
    printf '%s=0\n' "$label"
    return
  fi
  count="$(wc -l <<<"$names" | tr -d ' ')"
  printf '%s=%s [%s] retained_non_orphan=true no_direct_charge=true\n' \
    "$label" "$count" "$(paste -sd, <<<"$names")"
}

printf 'Orphan check\nproject=%s\n' "$PROJECT_ID"
for stack in "${stacks[@]}"; do
  if [[ -f "$stack/terraform.tfstate" ]]; then
    state_names="$(terraform -chdir="$stack" state list 2>/dev/null || true)"
  else
    state_names=""
  fi
  managed_state_names="$(
    grep -Ev '(^|\.)data\.' <<<"$state_names" || true
  )"
  data_source_state_names="$(
    grep -E '(^|\.)data\.' <<<"$state_names" || true
  )"
  record_names "terraform_managed_state_${stack#infra/}" \
    "$managed_state_names"
  report_transient_names "terraform_data_source_state_${stack#infra/}" \
    "$data_source_state_names"
done

enabled_services="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      services list --enabled --format='value(config.name)'
)"
service_enabled() {
  grep -Fxq "$1" <<<"$enabled_services"
}

if service_enabled container.googleapis.com; then
  record_names gke_clusters "$(
    gcloud_scoped container clusters list --format='value(name,location)'
  )"
else
  printf 'gke_clusters=0 (API disabled)\n'
fi

if service_enabled compute.googleapis.com; then
  record_names compute_instances "$(gcloud_scoped compute instances list --format='value(name,zone)')"
  record_names compute_disks "$(gcloud_scoped compute disks list --format='value(name,zone)')"
  record_names compute_snapshots "$(gcloud_scoped compute snapshots list --format='value(name)')"
  record_names forwarding_rules "$(gcloud_scoped compute forwarding-rules list --format='value(name,region)')"
  record_names backend_services "$(gcloud_scoped compute backend-services list --format='value(name)')"
  record_names url_maps "$(gcloud_scoped compute url-maps list --format='value(name)')"
  record_names target_http_proxies "$(gcloud_scoped compute target-http-proxies list --format='value(name)')"
  record_names target_https_proxies "$(gcloud_scoped compute target-https-proxies list --format='value(name)')"
  record_names health_checks "$(gcloud_scoped compute health-checks list --format='value(name)')"
  record_names addresses "$(gcloud_scoped compute addresses list --format='value(name,region)')"
  record_names networks "$(gcloud_scoped compute networks list --format='value(name)')"
  record_names subnetworks "$(gcloud_scoped compute networks subnets list --format='value(name,region)')"
  record_names firewall_rules "$(gcloud_scoped compute firewall-rules list --format='value(name)')"
  record_names network_endpoint_groups "$(gcloud_scoped compute network-endpoint-groups list --format='value(name,zone)')"
  record_names security_policies "$(gcloud_scoped compute security-policies list --format='value(name)')"
else
  printf 'compute_resources=0 (API disabled)\n'
fi

if service_enabled artifactregistry.googleapis.com; then
  record_names artifact_repositories "$(
    gcloud_scoped artifacts repositories list \
      --location=all --format='value(name)'
  )"
else
  printf 'artifact_repositories=0 (API disabled)\n'
fi

if service_enabled storage.googleapis.com; then
  record_names storage_buckets "$(
    gcloud_scoped storage buckets list --format='value(name)'
  )"
else
  printf 'storage_buckets=0 (API disabled)\n'
fi

if service_enabled bigquery.googleapis.com; then
  access_token="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      auth print-access-token
  )"
  trap 'unset access_token' EXIT
  datasets_json="$(
    printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
      | curl --config - --silent --show-error --fail-with-body --max-time 30 \
        "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/datasets?all=true"
  )"
  record_names bigquery_named_datasets "$(
    jq -r '.datasets[]?.datasetReference.datasetId | select(startswith("_") | not)' \
      <<<"$datasets_json"
  )"
  report_transient_names bigquery_anonymous_datasets "$(
    jq -r '.datasets[]?.datasetReference.datasetId | select(startswith("_"))' \
      <<<"$datasets_json"
  )"
else
  printf 'bigquery_named_datasets=0 (API disabled)\n'
  printf 'bigquery_anonymous_datasets=0 (API disabled)\n'
fi

if service_enabled cloudquotas.googleapis.com; then
  report_retained_names quota_preferences "$(
    gcloud beta quotas preferences list \
      --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      --format='value(name)' \
      | sed '/^None$/d'
  )"
else
  printf 'quota_preferences=0 (API disabled)\n'
fi

record_names assessment_service_accounts "$(
  gcloud_scoped iam service-accounts list --format='value(email)' \
    | grep -E '^(risk-gke-usc1-nodes|risk-gke-use4-nodes|risk-cloud-build|grafana-reader|currency-app-a-caller|currency-app-a-deployer|currency-app-b-deployer|currency-app-a-dev|currency-app-b-dev)@' \
    || true
)"
record_names assessment_log_sinks "$(
  gcloud_scoped logging sinks list --format='value(name)' \
    --filter='name=risk-app-stdout-to-bigquery'
)"

if service_enabled binaryauthorization.googleapis.com; then
  binauthz_policy="$(
    gcloud_scoped container binauthz policy export --format=json
  )"
  if jq -e '
      (.globalPolicyEvaluationMode == "ENABLE") and
      (.defaultAdmissionRule.evaluationMode == "ALWAYS_ALLOW") and
      ((.admissionWhitelistPatterns // []) == []) and
      ((.clusterAdmissionRules // {}) == {}) and
      ((.kubernetesNamespaceAdmissionRules // {}) == {}) and
      ((.kubernetesServiceAccountAdmissionRules // {}) == {})
    ' <<<"$binauthz_policy" >/dev/null; then
    printf 'binary_authorization_enforced_policy=0\n'
  else
    record_names binary_authorization_enforced_policy "$PROJECT_ID/policy"
  fi
else
  printf 'binary_authorization_enforced_policy=0 (API disabled)\n'
fi

if ((orphan_count > 0)); then
  printf 'overall=FAIL orphan_count=%s\n' "$orphan_count"
  exit 1
fi
printf 'overall=PASS orphan_count=0 project_retained=true\n'

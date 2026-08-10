#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "${ENABLE_BINARY_AUTHORIZATION:-0}" == "1" ]] || {
  printf '%s\n' \
    'Binary Authorization is implemented but disabled; set ENABLE_BINARY_AUTHORIZATION=1 only for an approved paid run.' >&2
  exit 2
}

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
[[ "$PROJECT_ID" == "$expected_project" ]] || {
  printf 'Expected project %s, received %s.\n' "$expected_project" "$PROJECT_ID" >&2
  exit 1
}
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] || {
  printf 'Expected gcloud configuration %s, received %s.\n' \
    "$expected_configuration" "$GCLOUD_CONFIGURATION" >&2
  exit 1
}

for command_name in gcloud jq timeout; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required.\n' "$command_name" >&2
    exit 1
  }
done

expected_patterns="$(
  printf '%s\n' \
    "us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-a" \
    "us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b" \
    | jq -R . \
    | jq -s 'sort'
)"

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
[[ "$active_account" == "$expected_account" ]] || {
  printf 'Expected gcloud account %s, found %s.\n' \
    "$expected_account" "${active_account:-<none>}" >&2
  exit 1
}

configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"
[[ "$configured_project" == "$PROJECT_ID" ]] || {
  printf 'Expected gcloud project %s, found %s.\n' \
    "$PROJECT_ID" "${configured_project:-<none>}" >&2
  exit 1
}

enabled_services="$(
  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    services list \
    --project="$PROJECT_ID" \
    --enabled \
    --filter='config.name:(binaryauthorization.googleapis.com OR containeranalysis.googleapis.com)' \
    --format='value(config.name)' \
    | tr -d '\r'
)"
jq -e '
  split("\n")
  | map(select(length > 0))
  | sort
  == ["binaryauthorization.googleapis.com", "containeranalysis.googleapis.com"]
' <<<"$enabled_services" >/dev/null || {
  printf 'Binary Authorization and Container Analysis APIs are not both enabled.\n' >&2
  exit 1
}

policy_json="$(
  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    container binauthz policy export \
    --project="$PROJECT_ID" \
    --format=json
)"
jq -e \
  --arg project "$PROJECT_ID" \
  --argjson patterns "$expected_patterns" \
  '
    (.name == ("projects/" + $project + "/policy"))
    and (.globalPolicyEvaluationMode == "ENABLE")
    and (.defaultAdmissionRule.evaluationMode == "ALWAYS_DENY")
    and (.defaultAdmissionRule.enforcementMode == "ENFORCED_BLOCK_AND_AUDIT_LOG")
    and ([.admissionWhitelistPatterns[]?.namePattern] | sort == $patterns)
    and ((.clusterAdmissionRules // {}) == {})
    and ((.kubernetesNamespaceAdmissionRules // {}) == {})
    and ((.kubernetesServiceAccountAdmissionRules // {}) == {})
    and ((.istioServiceIdentityAdmissionRules // {}) == {})
  ' <<<"$policy_json" >/dev/null || {
  printf 'The live Binary Authorization policy does not match the exact allowlist contract.\n' >&2
  exit 1
}

verify_cluster() {
  local name="$1"
  local location="$2"
  local cluster_json

  cluster_json="$(
    timeout --foreground --signal=INT 2m \
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" \
      container clusters describe "$name" \
      --project="$PROJECT_ID" \
      --location="$location" \
      --format=json
  )"

  jq -e '
    .binaryAuthorization.evaluationMode == "PROJECT_SINGLETON_POLICY_ENFORCE"
  ' <<<"$cluster_json" >/dev/null || {
    printf 'Cluster %s does not enforce the project Binary Authorization policy.\n' \
      "$name" >&2
    exit 1
  }

  printf 'Verified Binary Authorization enforcement on %s.\n' "$name"
}

verify_cluster gke-risk-usc1 us-central1
verify_cluster gke-risk-use4 us-east4

printf '%s\n' \
  'Verified default-deny Binary Authorization, two exact application image paths,' \
  'Google system-image evaluation, and enforcement on both clusters.'

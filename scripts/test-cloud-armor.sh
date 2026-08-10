#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
expected_policy="currency-edge-waf"
mode="${1:-verify}"
runtime_dir="$repo_root/.tmp"
work_dir=""

fail() {
  printf 'test-cloud-armor: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/cloud-armor.*) rm -rf -- "$work_dir" ;;
    esac
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

[[ "$mode" == "verify" || "$mode" == "exercise" ]] \
  || fail "usage: $0 [verify|exercise]"
: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "${ENABLE_CLOUD_ARMOR:-0}" == "1" ]] \
  || fail "Cloud Armor is implemented but disabled; set ENABLE_CLOUD_ARMOR=1 only for an approved paid run"
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"

for command_name in curl date gcloud grep jq terraform timeout wc; do
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

gcloud_json() {
  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    "$@" --format=json
}

lb_outputs="$(terraform -chdir=infra/30-lb output -json)"
endpoint="$(jq -r '.public_endpoint.value // ""' <<<"$lb_outputs")"
jq -e '
  (.security_policy_name.value == "currency-edge-waf") and
  (.tls_enabled.value == true) and
  (.public_endpoint.value == "https://satish.store")
' <<<"$lb_outputs" >/dev/null \
  || fail "30-lb state is not the trusted currency edge"

policy_json="$(gcloud_json compute security-policies describe "$expected_policy" --global)"
backend_json="$(
  gcloud_json compute backend-services describe risk-app-a-gateway-backend --global
)"
jq -e '
  (.name == "currency-edge-waf") and
  (.type == "CLOUD_ARMOR") and
  ((.rules | length) == 4) and
  any(.rules[];
    .priority == 1000 and .action == "deny(403)" and .preview == true and
    .match.expr.expression ==
      "evaluatePreconfiguredWaf(\u0027sqli-v422-stable\u0027, {\u0027sensitivity\u0027: 1})") and
  any(.rules[];
    .priority == 1010 and .action == "deny(403)" and .preview == true and
    .match.expr.expression ==
      "evaluatePreconfiguredWaf(\u0027xss-v422-stable\u0027, {\u0027sensitivity\u0027: 1})") and
  any(.rules[];
    .priority == 2000 and .action == "rate_based_ban" and
    (.preview // false) == false and
    .match.config.srcIpRanges == ["*"] and
    .rateLimitOptions.conformAction == "allow" and
    .rateLimitOptions.exceedAction == "deny(429)" and
    .rateLimitOptions.enforceOnKey == "IP" and
    .rateLimitOptions.rateLimitThreshold == {"count":120,"intervalSec":60} and
    .rateLimitOptions.banThreshold == {"count":600,"intervalSec":60} and
    .rateLimitOptions.banDurationSec == 60) and
  any(.rules[];
    .priority == 2147483647 and .action == "allow" and
    (.preview // false) == false and .match.config.srcIpRanges == ["*"])
' <<<"$policy_json" >/dev/null \
  || fail "live Cloud Armor policy does not match the frozen rule contract"
jq -e '
  (.securityPolicy | endswith("/global/securityPolicies/currency-edge-waf")) and
  (.logConfig.enable == true) and
  (.logConfig.sampleRate == 1)
' <<<"$backend_json" >/dev/null \
  || fail "backend is not attached to Cloud Armor with full request logging"

printf 'Cloud Armor policy verified: preview SQLi/XSS, 120/min per-IP limit, 600/min repeat-offender ban threshold.\n'

if [[ "$mode" == "verify" ]]; then
  exit 0
fi

mkdir -p "$runtime_dir"
work_dir="$(mktemp -d "$runtime_dir/cloud-armor.XXXXXX")"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

for probe in \
  'q=<script>alert(1)</script>' \
  "q=' OR 1=1--"; do
  status="$(
    curl --silent --show-error --max-time 15 --output /dev/null \
      --write-out '%{http_code}' --get --data-urlencode "$probe" "$endpoint/"
  )"
  [[ "$status" == "200" ]] \
    || fail "preview WAF probe returned HTTP $status instead of remaining non-blocking"
done

status_file="$work_dir/rate-statuses.txt"
: >"$status_file"
for ((request_number = 1; request_number <= 360; request_number++)); do
  (
    request_status="$(
      curl --silent --show-error --max-time 20 --output /dev/null \
        --write-out '%{http_code}' "$endpoint/api/exchange-rates" 2>/dev/null
    )" || request_status="000"
    printf '%s\n' "$request_status" >>"$status_file"
  ) &
  if ((request_number % 20 == 0)); then
    wait
  fi
done
wait

total="$(wc -l <"$status_file" | tr -d '[:space:]')"
allowed="$(grep -c '^200$' "$status_file" || true)"
denied="$(grep -c '^429$' "$status_file" || true)"
unexpected="$((total - allowed - denied))"
[[ "$total" == "360" ]] || fail "expected 360 bounded requests, recorded $total"
((denied > 0)) || fail "the bounded burst did not produce a rate-limit denial"
((unexpected == 0)) \
  || fail "$unexpected burst requests returned a status other than 200 or 429"

log_filter="resource.type=\"http_load_balancer\" AND timestamp>=\"$started_at\" AND (jsonPayload.enforcedSecurityPolicy.name=\"$expected_policy\" OR jsonPayload.previewSecurityPolicy.name=\"$expected_policy\")"
deadline=$((SECONDS + 300))
logs='[]'
while ((SECONDS < deadline)); do
  logs="$(
    gcloud_json logging read "$log_filter" \
      --freshness=10m --order=asc --limit=1000
  )"
  if jq -e '
      any(.[];
        .jsonPayload.enforcedSecurityPolicy.configuredAction == "RATE_BASED_BAN" and
        .jsonPayload.enforcedSecurityPolicy.outcome == "DENY" and
        .jsonPayload.statusDetails == "denied_by_security_policy") and
      any(.[]; .jsonPayload.previewSecurityPolicy.priority == 1000) and
      any(.[]; .jsonPayload.previewSecurityPolicy.priority == 1010)
    ' <<<"$logs" >/dev/null; then
    break
  fi
  sleep 10
done

jq -e '
  any(.[];
    .jsonPayload.enforcedSecurityPolicy.configuredAction == "RATE_BASED_BAN" and
    .jsonPayload.enforcedSecurityPolicy.outcome == "DENY" and
    .jsonPayload.statusDetails == "denied_by_security_policy") and
  any(.[]; .jsonPayload.previewSecurityPolicy.priority == 1000) and
  any(.[]; .jsonPayload.previewSecurityPolicy.priority == 1010)
' <<<"$logs" >/dev/null \
  || fail "Cloud Logging did not show the rate denial and both preview WAF matches"

recovered=false
recovery_deadline=$((SECONDS + 90))
while ((SECONDS < recovery_deadline)); do
  set +e
  recovery_status="$(
    curl --silent --show-error --max-time 15 --output /dev/null \
      --write-out '%{http_code}' "$endpoint/api/exchange-rates" 2>/dev/null
  )"
  recovery_curl_status=$?
  set -e
  ((recovery_curl_status == 0)) || recovery_status="000"
  if [[ "$recovery_status" == "200" ]]; then
    recovered=true
    break
  fi
  [[ "$recovery_status" == "429" ]] \
    || fail "post-rate-limit recovery returned unexpected HTTP $recovery_status"
  sleep 5
done
[[ "$recovered" == true ]] \
  || fail "the public endpoint did not recover from rate limiting within 90 seconds"

printf 'Bounded rate test: total=%s allowed=%s denied_429=%s unexpected=%s\n' \
  "$total" "$allowed" "$denied" "$unexpected"
jq '[.[] |
  select(
    .jsonPayload.enforcedSecurityPolicy.outcome == "DENY" or
    (.jsonPayload.previewSecurityPolicy.priority == 1000) or
    (.jsonPayload.previewSecurityPolicy.priority == 1010)
  ) |
  {
    timestamp,
    http_status: .httpRequest.status,
    status_details: .jsonPayload.statusDetails,
    enforced_policy: .jsonPayload.enforcedSecurityPolicy.name,
    enforced_priority: .jsonPayload.enforcedSecurityPolicy.priority,
    enforced_action: .jsonPayload.enforcedSecurityPolicy.configuredAction,
    enforced_outcome: .jsonPayload.enforcedSecurityPolicy.outcome,
    rate_outcome: .jsonPayload.enforcedSecurityPolicy.rateLimitAction.outcome,
    preview_policy: .jsonPayload.previewSecurityPolicy.name,
    preview_priority: .jsonPayload.previewSecurityPolicy.priority,
    preview_action: .jsonPayload.previewSecurityPolicy.configuredAction
  }
] | unique_by(.enforced_priority, .preview_priority, .rate_outcome)' \
  <<<"$logs"
printf 'Cloud Armor evidence contains an enforced 429, non-blocking SQLi/XSS preview matches, and a recovered HTTP 200.\n'

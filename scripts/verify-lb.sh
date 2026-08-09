#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
backend_name="risk-app-a-gateway-backend"
health_check_name="risk-app-a-cell-health"
runtime_dir="$repo_root/.tmp"
kubeconfig="$runtime_dir/kubeconfig-schwab-assessment"
work_dir=""
health_timeout_seconds="${LB_HEALTH_TIMEOUT_SECONDS:-900}"
health_poll_seconds="${LB_HEALTH_POLL_SECONDS:-10}"
certificate_timeout_seconds="${CERTIFICATE_TIMEOUT_SECONDS:-900}"
certificate_poll_seconds="${CERTIFICATE_POLL_SECONDS:-15}"
endpoint_timeout_seconds="${PUBLIC_ENDPOINT_TIMEOUT_SECONDS:-120}"

fail() {
  printf 'verify-lb: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/verify-lb.*)
        rm -f -- "$work_dir"/*
        rmdir -- "$work_dir" 2>/dev/null || true
        ;;
    esac
  fi

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project, received $PROJECT_ID"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration, received $GCLOUD_CONFIGURATION"

validate_timeout() {
  local name="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"

  [[ "$value" =~ ^[0-9]+$ ]] \
    && ((value >= minimum && value <= maximum)) \
    || fail "$name must be between $minimum and $maximum seconds"
}

validate_timeout LB_HEALTH_TIMEOUT_SECONDS "$health_timeout_seconds" 30 3600
validate_timeout LB_HEALTH_POLL_SECONDS "$health_poll_seconds" 2 60
validate_timeout CERTIFICATE_TIMEOUT_SECONDS "$certificate_timeout_seconds" 30 3600
validate_timeout CERTIFICATE_POLL_SECONDS "$certificate_poll_seconds" 2 60
validate_timeout PUBLIC_ENDPOINT_TIMEOUT_SECONDS "$endpoint_timeout_seconds" 30 300

for command_name in curl gcloud git jq kubectl terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
[[ -f "$repo_root/testdata/request.json" ]] \
  || fail "the canonical synthetic request is missing"

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

gcloud_json() {
  timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    "$@" --format=json
}

lb_outputs="$(terraform -chdir=infra/30-lb output -json)"
global_outputs="$(terraform -chdir=infra/10-global output -json)"

jq -e '
  has("domain_name") and
  has("certificate_map_id") and
  (
    ((.domain_name.value // "") == "" and
      (.certificate_map_id.value // "") == "") or
    (
      ((.domain_name.value // "") | length) > 0 and
      ((.certificate_map_id.value // "")
        | endswith("/certificateMaps/risk-cert-map"))
    )
  )
' <<<"$global_outputs" >/dev/null \
  || fail "10-global must export a paired domain name and risk-cert-map, or neither"

state_domain="$(jq -r '.domain_name.value // ""' <<<"$global_outputs")"
certificate_map_id="$(jq -r '.certificate_map_id.value // ""' <<<"$global_outputs")"
global_address="$(jq -r '.global_ipv4_address.value // ""' <<<"$global_outputs")"
requested_domain="$(
  printf '%s' "${DOMAIN_NAME:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[.]$//'
)"
[[ "$requested_domain" == "$state_domain" ]] \
  || fail "DOMAIN_NAME does not match the normalized domain exported by 10-global"

tls_enabled=false
expected_endpoint="http://$global_address"
if [[ -n "$state_domain" ]]; then
  tls_enabled=true
  expected_endpoint="https://$state_domain"
fi

jq -e \
  --arg address "$global_address" \
  --arg endpoint "$expected_endpoint" \
  --argjson tls_enabled "$tls_enabled" '
    (.backend_service_name.value == "risk-app-a-gateway-backend") and
    (.health_check_name.value == "risk-app-a-cell-health") and
    (.global_ipv4_address.value == $address) and
    (.public_endpoint.value == $endpoint) and
    (.tls_enabled.value == $tls_enabled) and
    (.forwarding_rule_names.value.http == "risk-app-a-http") and
    (
      if $tls_enabled then
        .forwarding_rule_names.value.https == "risk-app-a-https"
      else
        .forwarding_rule_names.value.https == null
      end
    ) and
    ((.neg_backends.value | keys | sort) == [
      "us-central1-a", "us-central1-b", "us-central1-c",
      "us-east4-a", "us-east4-b", "us-east4-c"
    ]) and
    (.neg_backends.value as $negs |
      ($negs["us-central1-a"].name == "app-a-neg-usc1") and
      ($negs["us-central1-b"].name == "app-a-neg-usc1") and
      ($negs["us-central1-c"].name == "app-a-neg-usc1") and
      ($negs["us-east4-a"].name == "app-a-neg-use4") and
      ($negs["us-east4-b"].name == "app-a-neg-use4") and
      ($negs["us-east4-c"].name == "app-a-neg-use4") and
      all($negs | to_entries[];
        . as $entry |
        ($entry.value.self_link | endswith(
          "/zones/\($entry.key)/networkEndpointGroups/\($entry.value.name)"
        )) and
        ($entry.value.endpoints >= 0)
      ) and
      (["us-central1-a", "us-central1-b", "us-central1-c"]
        | map($negs[.].endpoints) | add) >= 2 and
      (["us-east4-a", "us-east4-b", "us-east4-c"]
        | map($negs[.].endpoints) | add) >= 2
    )
  ' <<<"$lb_outputs" >/dev/null \
  || fail "30-lb Terraform outputs do not match the frozen edge contract"

health_check_json="$(
  gcloud_json compute health-checks describe "$health_check_name" --global
)"
jq -e '
  (.name == "risk-app-a-cell-health") and
  (.type == "HTTP") and
  (.checkIntervalSec == 5) and
  (.timeoutSec == 2) and
  (.unhealthyThreshold == 2) and
  (.healthyThreshold == 3) and
  (.httpHealthCheck.requestPath == "/health/cell") and
  (.httpHealthCheck.portSpecification == "USE_SERVING_PORT") and
  (.httpHealthCheck.proxyHeader == "NONE") and
  (.logConfig.enable == true)
' <<<"$health_check_json" >/dev/null \
  || fail "the live App A cell health check does not match the frozen settings"

backend_json="$(
  gcloud_json compute backend-services describe "$backend_name" --global
)"
jq -e --arg project "$PROJECT_ID" '
  (.name == "risk-app-a-gateway-backend") and
  (.loadBalancingScheme == "EXTERNAL_MANAGED") and
  (.protocol == "HTTP") and
  (.localityLbPolicy == "ROUND_ROBIN") and
  (.sessionAffinity == "NONE") and
  (.timeoutSec == 10) and
  (.connectionDraining.drainingTimeoutSec == 30) and
  ((.healthChecks | length) == 1) and
  (.healthChecks[0] | endswith("/global/healthChecks/risk-app-a-cell-health")) and
  ((.backends | length) == 6) and
  all(.backends[];
    (.balancingMode == "RATE") and
    (.maxRatePerEndpoint == 20) and
    (.capacityScaler == 1)
  ) and
  ([.backends[] |
    (.group | capture(
      "/projects/(?<project>[^/]+)/zones/(?<zone>[^/]+)/networkEndpointGroups/(?<name>[^/]+)$"
    ))
  ] | sort_by(.zone)) == ([
    {"project":$project,"zone":"us-central1-a","name":"app-a-neg-usc1"},
    {"project":$project,"zone":"us-central1-b","name":"app-a-neg-usc1"},
    {"project":$project,"zone":"us-central1-c","name":"app-a-neg-usc1"},
    {"project":$project,"zone":"us-east4-a","name":"app-a-neg-use4"},
    {"project":$project,"zone":"us-east4-b","name":"app-a-neg-use4"},
    {"project":$project,"zone":"us-east4-c","name":"app-a-neg-use4"}
  ] | sort_by(.zone))
' <<<"$backend_json" >/dev/null \
  || fail "the live backend service or its exact six NEG attachments is invalid"

address_json="$(
  gcloud_json compute addresses describe risk-global-ip --global
)"
jq -e --arg address "$global_address" '
  (.name == "risk-global-ip") and
  (.address == $address) and
  (.addressType == "EXTERNAL") and
  ((.ipVersion // "IPV4") == "IPV4") and
  (.status == "IN_USE")
' <<<"$address_json" >/dev/null \
  || fail "the live global address is not the exact in-use IPv4 output"

application_map_json="$(
  gcloud_json compute url-maps describe risk-app-a-gateway-map --global
)"
jq -e '
  (.name == "risk-app-a-gateway-map") and
  (.defaultService | endswith(
    "/global/backendServices/risk-app-a-gateway-backend"
  )) and
  ((.hostRules // []) == []) and
  ((.pathMatchers // []) == [])
' <<<"$application_map_json" >/dev/null \
  || fail "the application URL map does not route only to the frozen backend"

http_proxy_json="$(
  gcloud_json compute target-http-proxies describe risk-app-a-http-proxy --global
)"
http_rule_json="$(
  gcloud_json compute forwarding-rules describe risk-app-a-http --global
)"

expected_http_map="risk-app-a-gateway-map"
if [[ "$tls_enabled" == true ]]; then
  expected_http_map="risk-app-a-http-redirect"
fi
jq -e --arg map "$expected_http_map" '
  (.name == "risk-app-a-http-proxy") and
  (.urlMap | endswith("/global/urlMaps/\($map)"))
' <<<"$http_proxy_json" >/dev/null \
  || fail "the live HTTP proxy points to the wrong URL map"
jq -e --arg address "$global_address" '
  (.name == "risk-app-a-http") and
  (.IPAddress == $address) and
  (.IPProtocol == "TCP") and
  (.loadBalancingScheme == "EXTERNAL_MANAGED") and
  (.networkTier == "PREMIUM") and
  ((.portRange == "80") or (.portRange == "80-80")) and
  (.target | endswith("/global/targetHttpProxies/risk-app-a-http-proxy"))
' <<<"$http_rule_json" >/dev/null \
  || fail "the live HTTP forwarding rule does not match the frozen frontend"

forwarding_inventory="$(
  gcloud_json compute forwarding-rules list --global
)"
http_proxy_inventory="$(
  gcloud_json compute target-http-proxies list --global
)"
https_proxy_inventory="$(
  gcloud_json compute target-https-proxies list --global
)"
url_map_inventory="$(
  gcloud_json compute url-maps list --global
)"

if [[ "$tls_enabled" == true ]]; then
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name] | sort
      == ["risk-app-a-http", "risk-app-a-https"]
  ' <<<"$forwarding_inventory" >/dev/null \
    || fail "the risk frontend forwarding-rule inventory is not exactly HTTP and HTTPS"
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name]
      == ["risk-app-a-http-proxy"]
  ' <<<"$http_proxy_inventory" >/dev/null \
    || fail "the risk HTTP proxy inventory is not exact"
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name]
      == ["risk-app-a-https-proxy"]
  ' <<<"$https_proxy_inventory" >/dev/null \
    || fail "the risk HTTPS proxy inventory is not exact"
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name] | sort
      == ["risk-app-a-gateway-map", "risk-app-a-http-redirect"]
  ' <<<"$url_map_inventory" >/dev/null \
    || fail "the risk URL-map inventory is not exactly application plus redirect"

  redirect_map_json="$(
    gcloud_json compute url-maps describe risk-app-a-http-redirect --global
  )"
  https_proxy_json="$(
    gcloud_json compute target-https-proxies describe risk-app-a-https-proxy --global
  )"
  https_rule_json="$(
    gcloud_json compute forwarding-rules describe risk-app-a-https --global
  )"
  certificate_map_json="$(
    gcloud_json certificate-manager maps describe risk-cert-map --location=global
  )"
  certificate_entry_json="$(
    gcloud_json certificate-manager maps entries describe risk-domain \
      --map=risk-cert-map --location=global
  )"

  jq -e --arg domain "$state_domain" '
    (.name == "risk-app-a-http-redirect") and
    (.defaultUrlRedirect.hostRedirect == $domain) and
    (.defaultUrlRedirect.httpsRedirect == true) and
    (.defaultUrlRedirect.redirectResponseCode == "PERMANENT_REDIRECT") and
    ((.defaultUrlRedirect.stripQuery // false) == false)
  ' <<<"$redirect_map_json" >/dev/null \
    || fail "the HTTP redirect does not preserve POST semantics for the trusted domain"
  jq -e --arg map "$certificate_map_id" '
    (.name == "risk-app-a-https-proxy") and
    (.urlMap | endswith("/global/urlMaps/risk-app-a-gateway-map")) and
    ((.certificateMap | ltrimstr("//certificatemanager.googleapis.com/")) == $map) and
    ((.quicOverride // "NONE") == "NONE")
  ' <<<"$https_proxy_json" >/dev/null \
    || fail "the HTTPS proxy does not use the paired Certificate Manager map"
  jq -e --arg address "$global_address" '
    (.name == "risk-app-a-https") and
    (.IPAddress == $address) and
    (.IPProtocol == "TCP") and
    (.loadBalancingScheme == "EXTERNAL_MANAGED") and
    (.networkTier == "PREMIUM") and
    ((.portRange == "443") or (.portRange == "443-443")) and
    (.target | endswith("/global/targetHttpsProxies/risk-app-a-https-proxy"))
  ' <<<"$https_rule_json" >/dev/null \
    || fail "the HTTPS forwarding rule does not match the frozen frontend"
  jq -e '
    (.name | endswith("/locations/global/certificateMaps/risk-cert-map"))
  ' <<<"$certificate_map_json" >/dev/null \
    || fail "the live Certificate Manager map has the wrong identity"
  jq -e --arg domain "$state_domain" '
    (.name | endswith(
      "/locations/global/certificateMaps/risk-cert-map/certificateMapEntries/risk-domain"
    )) and
    (.hostname == $domain) and
    (.certificates == [
      "projects/" + $ENV.PROJECT_ID + "/locations/global/certificates/risk-cert"
    ])
  ' <<<"$certificate_entry_json" >/dev/null \
    || fail "the certificate-map entry is not paired to the trusted domain and risk-cert"

  certificate_deadline=$((SECONDS + certificate_timeout_seconds))
  certificate_state=""
  while ((SECONDS < certificate_deadline)); do
    certificate_json="$(
      gcloud_json certificate-manager certificates describe risk-cert \
        --location=global
    )"
    certificate_state="$(jq -r '.managed.state // ""' <<<"$certificate_json")"
    if [[ "$certificate_state" == "ACTIVE" ]] \
      && jq -e --arg domain "$state_domain" '
        (.name | endswith("/locations/global/certificates/risk-cert")) and
        (.managed.domains == [$domain])
      ' <<<"$certificate_json" >/dev/null; then
      printf 'Managed certificate risk-cert is ACTIVE for %s.\n' "$state_domain"
      break
    fi
    sleep "$certificate_poll_seconds"
  done
  [[ "$certificate_state" == "ACTIVE" ]] \
    || fail "managed certificate risk-cert did not become ACTIVE within ${certificate_timeout_seconds}s"
else
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name]
      == ["risk-app-a-http"]
  ' <<<"$forwarding_inventory" >/dev/null \
    || fail "the core risk frontend must contain only its HTTP forwarding rule"
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name]
      == ["risk-app-a-http-proxy"]
  ' <<<"$http_proxy_inventory" >/dev/null \
    || fail "the core risk frontend must contain only its HTTP proxy"
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-"))] | length == 0
  ' <<<"$https_proxy_inventory" >/dev/null \
    || fail "an HTTPS proxy exists without a paired domain and certificate map"
  jq -e '
    [.[] | select(.name | startswith("risk-app-a-")) | .name]
      == ["risk-app-a-gateway-map"]
  ' <<<"$url_map_inventory" >/dev/null \
    || fail "the core risk frontend must contain only its application URL map"
fi

health_deadline=$((SECONDS + health_timeout_seconds))
usc1_healthy=0
use4_healthy=0
while ((SECONDS < health_deadline)); do
  backend_health_json="$(
    gcloud_json compute backend-services get-health "$backend_name" --global
  )"
  counts_json="$(
    jq -c '
      reduce .[] as $backend (
        {"us-central1": 0, "us-east4": 0};
        ($backend.backend // "") as $group |
        ([$backend.status.healthStatus[]?
          | select(.healthState == "HEALTHY")] | length) as $healthy |
        if ($group | contains("/zones/us-central1-")) then
          .["us-central1"] += $healthy
        elif ($group | contains("/zones/us-east4-")) then
          .["us-east4"] += $healthy
        else
          .
        end
      )
    ' <<<"$backend_health_json"
  )"
  usc1_healthy="$(jq -r '.["us-central1"]' <<<"$counts_json")"
  use4_healthy="$(jq -r '.["us-east4"]' <<<"$counts_json")"
  printf 'Backend health: us-central1=%s, us-east4=%s healthy endpoints.\n' \
    "$usc1_healthy" "$use4_healthy"
  if ((usc1_healthy >= 2 && use4_healthy >= 2)); then
    break
  fi
  sleep "$health_poll_seconds"
done
((usc1_healthy >= 2 && use4_healthy >= 2)) \
  || fail "both regions did not reach two healthy endpoints within ${health_timeout_seconds}s"

mkdir -p "$runtime_dir"
work_dir="$(mktemp -d "$runtime_dir/verify-lb.XXXXXX")"
response_file="$work_dir/public-response.json"
endpoint_deadline=$((SECONDS + endpoint_timeout_seconds))
http_status=""
while ((SECONDS < endpoint_deadline)); do
  http_status="$(
    curl --silent --show-error --max-time 20 \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request POST "$expected_endpoint/v1/risk" \
      --header 'Content-Type: application/json' \
      --data-binary "@$repo_root/testdata/request.json" 2>/dev/null || true
  )"
  [[ "$http_status" == "200" ]] && break
  sleep 5
done
[[ "$http_status" == "200" ]] \
  || fail "the public canonical request did not return HTTP 200 within ${endpoint_timeout_seconds}s (last status ${http_status:-<none>})"

jq -e '
  (keys | sort) == ["decision", "evaluatedBy", "requestId", "rulesFired", "score"] and
  (.requestId == "550e8400-e29b-41d4-a716-446655440000") and
  (.score == 48) and
  (.decision == "REVIEW") and
  (.rulesFired == ["CARD_NOT_PRESENT", "AMOUNT_OVER_1000"]) and
  ((.evaluatedBy | keys | sort) == ["cluster", "region", "service", "version"]) and
  (.evaluatedBy.service == "app-b-engine") and
  (
    (.evaluatedBy.region == "us-central1" and
      .evaluatedBy.cluster == "gke-risk-usc1") or
    (.evaluatedBy.region == "us-east4" and
      .evaluatedBy.cluster == "gke-risk-use4")
  ) and
  (.evaluatedBy.version | test("^[0-9a-f]{40}$"))
' "$response_file" >/dev/null \
  || fail "the public response is not the deterministic frozen schema from a real cell"

serving_region="$(jq -r '.evaluatedBy.region' "$response_file")"
serving_cluster="$(jq -r '.evaluatedBy.cluster' "$response_file")"
serving_version="$(jq -r '.evaluatedBy.version' "$response_file")"
git cat-file -e "$serving_version^{commit}" 2>/dev/null \
  || fail "the serving version is not a real commit in this repository"

[[ -f "$kubeconfig" ]] \
  || fail "the isolated two-cluster kubeconfig is missing; run the regional workload gate first"
case "$(uname -s)" in
  MINGW* | MSYS*) KUBECONFIG="$(cygpath -w "$kubeconfig")" ;;
  *) KUBECONFIG="$kubeconfig" ;;
esac
export KUBECONFIG

serving_deployment_json="$(
  kubectl --context="$serving_cluster" --namespace=risk-system \
    --request-timeout=20s get deployment app-b-engine -o json
)"
serving_config_json="$(
  kubectl --context="$serving_cluster" --namespace=risk-system \
    --request-timeout=20s get configmap runtime-config -o json
)"
expected_app_b_image="us-central1-docker.pkg.dev/$PROJECT_ID/risk/app-b:$serving_version"
jq -e --arg image "$expected_app_b_image" '
  (.metadata.name == "app-b-engine") and
  (.status.readyReplicas >= 2) and
  ([.spec.template.spec.containers[].image] == [$image])
' <<<"$serving_deployment_json" >/dev/null \
  || fail "the response version does not match the serving cluster App B image"
jq -e \
  --arg region "$serving_region" \
  --arg cluster "$serving_cluster" \
  --arg version "$serving_version" '
    (.data.RISK_REGION == $region) and
    (.data.RISK_CLUSTER == $cluster) and
    (.data.SERVICE_VERSION == $version)
  ' <<<"$serving_config_json" >/dev/null \
  || fail "the response cell identity does not match the serving cluster runtime configuration"

printf 'Verified the complete global edge: six exact NEGs, %s/%s healthy endpoints, and HTTP 200 from %s at %s.\n' \
  "$usc1_healthy" "$use4_healthy" "$serving_cluster" "$serving_version"

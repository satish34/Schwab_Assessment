#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
runtime_root="$repo_root/.tmp"
evidence_dir="$repo_root/evidence"

fail() {
  printf 'capture-evidence: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || {
  printf 'Usage: %s FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  exit 2
}
: "${PROJECT_ID:?PROJECT_ID is required}"
: "${BILLING_ACCOUNT_ID:?BILLING_ACCOUNT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

enable_cloud_armor="${ENABLE_CLOUD_ARMOR:-0}"
enable_binary_authorization="${ENABLE_BINARY_AUTHORIZATION:-0}"
for feature_flag in enable_cloud_armor enable_binary_authorization; do
  feature_value="${!feature_flag}"
  [[ "$feature_value" == "0" || "$feature_value" == "1" ]] \
    || fail "${feature_flag^^} must be 0 or 1"
done

app_a_sha="$1"
app_b_sha="$2"
[[ "$app_a_sha" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$app_b_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "both deployed image versions must be full lowercase Git SHAs"
for sha in "$app_a_sha" "$app_b_sha"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null \
    || fail "Git SHA $sha is not present in this repository"
done
[[ "$PROJECT_ID" == "$expected_project" ]] \
  || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"

for command_name in curl gcloud git jq kubectl python terraform timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
python -c 'import matplotlib' >/dev/null 2>&1 \
  || fail "the existing matplotlib Python package is required"
[[ -f "$repo_root/scripts/render-evidence.py" ]] \
  || fail "the evidence renderer is missing"
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

mkdir -p "$runtime_root" "$evidence_dir"
work_dir="$(mktemp -d "$runtime_root/capture-evidence.XXXXXX")"
cleanup() {
  case "$work_dir" in
    "$runtime_root"/capture-evidence.*) rm -rf -- "$work_dir" ;;
  esac
}
trap cleanup EXIT
git check-ignore --quiet -- "$work_dir" \
  || fail "the evidence work directory must stay ignored"

project_number="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      projects describe "$PROJECT_ID" --format='value(projectNumber)'
)"
[[ "$project_number" =~ ^[0-9]+$ ]] || fail "could not resolve project number"
budgets_json="$(
  timeout --foreground --signal=INT --kill-after=10s 1m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" billing budgets list \
      --billing-account="$BILLING_ACCOUNT_ID" --format=json
)"
jq -er \
  --arg name 'Schwab Assessment - 30 USD Safety Budget' \
  --arg project "projects/$project_number" '
    [.[] | select(.displayName == $name)] as $matches
    | select(($matches | length) == 1)
    | $matches[0]
    | select(.budgetFilter.projects == [$project])
    | select(.amount.specifiedAmount.currencyCode == "USD")
    | select((.amount.specifiedAmount.units | tonumber) == 30)
    | ([.thresholdRules[]
        | select(.spendBasis == "CURRENT_SPEND")
        | .thresholdPercent] | sort) as $thresholds
    | select($thresholds == [0.5, 0.8, 0.9, 1])
    | "project=schwab-assessment-gke\namount_usd=30\nspend_basis=CURRENT_SPEND\nthresholds=50%,80%,90%,100%"
  ' <<<"$budgets_json" >"$work_dir/01-budget.txt" \
  || fail "the live budget does not match the frozen contract"

bash "$repo_root/scripts/verify-workloads.sh" "$app_a_sha" "$app_b_sha" \
  >"$work_dir/02-clusters.txt" 2>&1
bash "$repo_root/scripts/verify-global.sh" \
  >"$work_dir/service-auth-global.txt" 2>&1
bash "$repo_root/scripts/verify-team-isolation.sh" \
  >"$work_dir/17-team-isolation.txt" 2>&1

auth_log_json="$work_dir/service-auth-logging.json"
auth_log_filter="resource.type=\"k8s_container\" AND resource.labels.namespace_name=\"currency-app-b\" AND jsonPayload.service=\"app-b-engine\" AND jsonPayload.service_version=\"$app_b_sha\" AND jsonPayload.decision=\"AUTH_REJECTED\" AND jsonPayload.status_code=401"
auth_deadline=$((SECONDS + 180))
while ((SECONDS < auth_deadline)); do
  timeout --foreground --signal=INT --kill-after=10s 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      logging read "$auth_log_filter" --freshness=30m --limit=100 \
      --order=desc --format=json >"$auth_log_json"
  if jq -e --arg version "$app_b_sha" '
      [ .[] | .jsonPayload
        | select(
            .service == "app-b-engine" and
            .service_version == $version and
            .status_code == 401 and
            .decision == "AUTH_REJECTED" and
            .route == "/internal/exchange-rates" and
            .method == "GET")
      ] as $entries
      | ($entries | map(.region) | unique | sort)
          == ["us-central1", "us-east4"]
    ' "$auth_log_json" >/dev/null; then
    break
  fi
  sleep 5
done
jq -e --arg version "$app_b_sha" '
  [ .[] | .jsonPayload
    | select(
        .service == "app-b-engine" and
        .service_version == $version and
        .status_code == 401 and
        .decision == "AUTH_REJECTED" and
        .route == "/internal/exchange-rates" and
        .method == "GET")
  ] as $entries
  | ($entries | map(.region) | unique | sort)
      == ["us-central1", "us-east4"]
' "$auth_log_json" >/dev/null \
  || fail "structured AUTH_REJECTED logs were not observed in both cells"
{
  command cat -- "$work_dir/service-auth-global.txt"
  jq --arg version "$app_b_sha" '
    [ .[]
      | {
          timestamp,
          service: .jsonPayload.service,
          service_version: .jsonPayload.service_version,
          region: .jsonPayload.region,
          cluster: .jsonPayload.cluster,
          log_type: .jsonPayload.log_type,
          method: .jsonPayload.method,
          route: .jsonPayload.route,
          status_code: .jsonPayload.status_code,
          decision: .jsonPayload.decision,
          rejection_type: .jsonPayload.error_type
        }
      | select(
          .service == "app-b-engine" and
          .service_version == $version and
          .status_code == 401 and
          .decision == "AUTH_REJECTED")
    ]
    | sort_by(.region)
    | unique_by(.region)
  ' "$auth_log_json"
  printf 'Authenticated App A requests reached App B successfully in the workload and trace gates; direct unauthenticated calls were empty 401 responses.\n'
} >"$work_dir/14-service-auth.txt"
! grep -Eiq 'authorization:|bearer[[:space:]]+eyj|"token"' "$work_dir/14-service-auth.txt" \
  || fail "service-auth evidence contains token-like material"

export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
evidence_kubeconfig="$runtime_root/kubeconfig-verifier"
[[ -s "$evidence_kubeconfig" ]] \
  || fail "the workload verifier did not leave its isolated kubeconfig"
case "$(uname -s)" in
  MINGW*|MSYS*) evidence_kubeconfig_cli="$(cygpath -w "$evidence_kubeconfig")" ;;
  *) evidence_kubeconfig_cli="$evidence_kubeconfig" ;;
esac
for context in gke-risk-usc1 gke-risk-use4; do
  nodes_file="$work_dir/nodes-$context.json"
  app_a_pods_file="$work_dir/app-a-pods-$context.json"
  app_b_pods_file="$work_dir/app-b-pods-$context.json"
  pods_file="$work_dir/pods-$context.json"
  MSYS_NO_PATHCONV=1 kubectl --kubeconfig="$evidence_kubeconfig_cli" \
    --context="$context" --request-timeout=20s get nodes -o json \
    >"$nodes_file"
  MSYS_NO_PATHCONV=1 kubectl --kubeconfig="$evidence_kubeconfig_cli" \
    --context="$context" --namespace=currency-app-a --request-timeout=20s \
    get pods --selector='app=app-a-gateway' -o json \
    >"$app_a_pods_file"
  MSYS_NO_PATHCONV=1 kubectl --kubeconfig="$evidence_kubeconfig_cli" \
    --context="$context" --namespace=currency-app-b --request-timeout=20s \
    get pods --selector='app=app-b-engine' -o json \
    >"$app_b_pods_file"
  jq -s '{items: (.[0].items + .[1].items)}' \
    "$app_a_pods_file" "$app_b_pods_file" >"$pods_file"
  jq -e '
    (.items | length) >= 3 and
    all(.items[];
      (.metadata.labels["topology.kubernetes.io/zone"] | type == "string") and
      any(.status.conditions[]?; .type == "Ready" and .status == "True")
    )
  ' "$nodes_file" >/dev/null \
    || fail "$context node evidence is incomplete"
  jq -e '
    ([.items[] | select(.metadata.labels.app == "app-a-gateway")] | length) >= 3 and
    ([.items[] | select(.metadata.labels.app == "app-b-engine")] | length) >= 2 and
    all(.items[];
      .status.phase == "Running" and
      any(.status.conditions[]?; .type == "Ready" and .status == "True")
    )
  ' "$pods_file" >/dev/null \
    || fail "$context ready-Pod evidence is incomplete"
  {
    printf '\n[%s] node inventory\n' "$context"
    printf 'NAME\tZONE\tREADY\tKUBELET\n'
    jq -r '
      .items | sort_by(.metadata.name)[] |
      [
        .metadata.name,
        .metadata.labels["topology.kubernetes.io/zone"],
        ([.status.conditions[] | select(.type == "Ready") | .status][0]),
        .status.nodeInfo.kubeletVersion
      ] | @tsv
    ' "$nodes_file"
    printf '[%s] ready workload Pods\n' "$context"
    printf 'NAME\tAPP\tSHARD\tNODE\tREADY\tIMAGE\n'
    jq -r '
      .items | sort_by(.metadata.name)[] |
      [
        .metadata.name,
        .metadata.labels.app,
        (.metadata.labels["app-a-shard"] // "-"),
        .spec.nodeName,
        ([.status.conditions[] | select(.type == "Ready") | .status][0]),
        .spec.containers[0].image
      ] | @tsv
    ' "$pods_file"
  } >>"$work_dir/02-clusters.txt"
done
bash "$repo_root/scripts/wait-negs.sh" "$app_a_sha" "$app_b_sha" \
  >"$work_dir/03-negs.txt" 2>&1
bash "$repo_root/scripts/verify-lb.sh" "$app_a_sha" "$app_b_sha" \
  >"$work_dir/04-backend-health-before.txt" 2>&1

lb_outputs="$(terraform -chdir=infra/30-lb output -json)"
jq -e '
  (.tls_enabled.value == true) and
  (.public_endpoint.value == "https://satish.store") and
  (.forwarding_rule_names.value.http == null) and
  (.forwarding_rule_names.value.https == "risk-app-a-https")
' <<<"$lb_outputs" >/dev/null \
  || fail "30-lb outputs do not describe the HTTPS-only public edge"
public_endpoint="$(jq -er '.public_endpoint.value' <<<"$lb_outputs")"
response_candidate="$work_dir/05-public-endpoint.json"
http_status="$(
  curl --silent --show-error --connect-timeout 5 --max-time 30 \
    --output "$response_candidate" --write-out '%{http_code}' \
    --request GET "$public_endpoint/api/exchange-rates" \
    --header 'Accept: application/json'
)"
[[ "$http_status" == "200" ]] || fail "public evidence request returned HTTP $http_status"
jq -e \
  --slurpfile expected "$repo_root/testdata/expected-exchange-rates.json" \
  --arg version "$app_b_sha" '
  (keys == ["baseCurrency", "disclaimer", "providedBy", "rateSnapshots"]) and
  (.rateSnapshots | length == 10) and
  all(.rateSnapshots[]; keys == ["EUR", "GBP", "JPY"]) and
  (.providedBy | keys == ["cluster", "region", "service", "version"]) and
  .baseCurrency == $expected[0].baseCurrency and
  .rateSnapshots == $expected[0].rateSnapshots and
  .disclaimer == $expected[0].disclaimer and
  .providedBy.service == $expected[0].providedBy.service and
  .providedBy.version == $version and
  ((.providedBy.region == "us-central1" and
    .providedBy.cluster == "gke-risk-usc1") or
   (.providedBy.region == "us-east4" and
    .providedBy.cluster == "gke-risk-use4"))
' "$response_candidate" >/dev/null \
  || fail "public response does not match the immutable contract"

logging_json="$work_dir/logging.json"
logging_filter="resource.type=\"k8s_container\" AND jsonPayload.log_type=\"request\" AND jsonPayload.method=\"GET\" AND ((resource.labels.namespace_name=\"currency-app-a\" AND jsonPayload.service=\"app-a-gateway\" AND jsonPayload.service_version=\"$app_a_sha\" AND jsonPayload.route=\"/api/exchange-rates\") OR (resource.labels.namespace_name=\"currency-app-b\" AND jsonPayload.service=\"app-b-engine\" AND jsonPayload.service_version=\"$app_b_sha\" AND jsonPayload.route=\"/internal/exchange-rates\"))"
timeout --foreground --signal=INT --kill-after=10s 2m \
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" --project="$PROJECT_ID" \
    logging read "$logging_filter" --freshness=6h --limit=2000 \
    --order=desc --format=json >"$logging_json"
jq -e '
  [ .[]
    | .jsonPayload
    | select(
        (.service == "app-a-gateway" or .service == "app-b-engine") and
        (.status_code == 200) and
        (.decision == "RATES_RETURNED") and
        (.correlation_id | type == "string") and
        (.correlation_id | length) == 36 and
        (.trace_id | type == "string") and
        (.trace_id | length) == 32)
    | {
        service, service_version, region, cluster, correlation_id, trace_id,
        status_code, decision, latency_ms, downstream_latency_ms
      }
  ]
  | sort_by(.correlation_id)
  | group_by(.correlation_id)
  | map(select(
      ([.[].service] | unique | sort) == ["app-a-gateway", "app-b-engine"] and
      ([.[].trace_id] | unique | length) == 1 and
      ([.[].region] | unique | length) == 1 and
      ([.[].cluster] | unique | length) == 1))
  | .[0]
  | select(. != null)
  | sort_by(.service)
' "$logging_json" >"$work_dir/06-logging.txt" \
  || fail "could not find a same-trace App A/App B logging pair"
jq -e 'length == 2' "$work_dir/06-logging.txt" >/dev/null \
  || fail "logging evidence does not contain exactly one service pair"

if ! BQ_SEED_MAX_AGE_SECONDS="${BQ_SEED_MAX_AGE_SECONDS:-21600}" \
  bash "$repo_root/scripts/verify-bigquery.sh" "$app_a_sha" "$app_b_sha" \
    >"$work_dir/bigquery-verifier.txt" 2>&1; then
  command cat -- "$work_dir/bigquery-verifier.txt" >&2
  fail "BigQuery evidence verification failed"
fi
for result in \
  01_error_rate.json 02_latency_percentiles.json \
  03_trace_join.json 04_regional_traffic.json \
  05_auth_rejections.json; do
  [[ -f "$runtime_root/bigquery-gate/$result" ]] \
    || fail "BigQuery result $result is missing"
done
table_metadata="$runtime_root/bigquery-gate/table-metadata.json"
[[ -s "$table_metadata" ]] \
  || fail "validated BigQuery table metadata is missing"
jq '
  {
    tableReference,
    location,
    timePartitioning,
    schema: {
      fields: [
        .schema.fields[]
        | select(.name == "timestamp" or .name == "jsonPayload")
        | if .name == "jsonPayload" then
            {
              name,
              type,
              mode,
              fields: (.fields | map({name, type, mode}) | sort_by(.name))
            }
          else
            {name, type, mode}
          end
      ]
    }
  }
' "$table_metadata" >"$work_dir/07-bigquery-schema.json"
jq -e '
  (.location == "US") and
  (.timePartitioning == {field: "timestamp", type: "DAY"}) and
  ([.schema.fields[] | select(.name == "timestamp" and .type == "TIMESTAMP")] | length == 1) and
  ([.schema.fields[] | select(.name == "jsonPayload" and .type == "RECORD")] | length == 1)
' "$work_dir/07-bigquery-schema.json" >/dev/null \
  || fail "sanitized BigQuery schema evidence is incomplete"
{
  command cat -- "$work_dir/bigquery-verifier.txt"
  printf 'error_rate_rows=%s\n' \
    "$(jq 'length' "$runtime_root/bigquery-gate/01_error_rate.json")"
  printf 'latency_rows=%s\n' \
    "$(jq 'length' "$runtime_root/bigquery-gate/02_latency_percentiles.json")"
  printf 'trace_join_rows=%s\n' \
    "$(jq 'length' "$runtime_root/bigquery-gate/03_trace_join.json")"
  printf 'regional_traffic_rows=%s\n' \
    "$(jq 'length' "$runtime_root/bigquery-gate/04_regional_traffic.json")"
  printf 'auth_rejection_rows=%s\n' \
    "$(jq 'length' "$runtime_root/bigquery-gate/05_auth_rejections.json")"
} >"$work_dir/07-bigquery.txt"

python "$repo_root/scripts/render-evidence.py" export-bigquery \
  --input-dir "$runtime_root/bigquery-gate" \
  --output-dir "$work_dir"
python "$repo_root/scripts/render-evidence.py" budget \
  --input "$work_dir/01-budget.txt" \
  --output "$work_dir/01-budget.png"
python "$repo_root/scripts/render-evidence.py" logging \
  --input "$work_dir/06-logging.txt" \
  --output "$work_dir/06-logging.png"
python "$repo_root/scripts/render-evidence.py" bigquery \
  --error-rate "$work_dir/07-bigquery-error-rate.csv" \
  --latency "$work_dir/07-bigquery-latency-percentiles.csv" \
  --trace-join "$work_dir/07-bigquery-trace-join.csv" \
  --regional-traffic "$work_dir/07-bigquery-regional-traffic.csv" \
  --output "$work_dir/07-bigquery.png"

if [[ "$enable_cloud_armor" == "1" ]]; then
  bash "$repo_root/scripts/test-cloud-armor.sh" exercise \
    >"$work_dir/15-cloud-armor.txt" 2>&1
else
  jq -e '
    (.cloud_armor_enabled.value == false) and
    (.security_policy_name.value == null)
  ' <<<"$lb_outputs" >/dev/null \
    || fail "Cloud Armor disabled-state Terraform outputs are invalid"
  {
    printf 'feature=Cloud Armor\n'
    printf 'implementation=Terraform feature flag ENABLE_CLOUD_ARMOR\n'
    printf 'live_state=disabled\n'
    printf 'cost_state=no Cloud Armor policy; backend request logging enabled at a bounded 5%% sample for platform observability\n'
    printf 'verification=verify-lb confirmed no attached policy and no currency-edge-waf resource\n'
  } >"$work_dir/15-cloud-armor.txt"
fi

if [[ "$enable_binary_authorization" == "1" ]]; then
  {
    bash "$repo_root/scripts/verify-binary-authorization.sh"
    bash "$repo_root/scripts/test-binary-authorization-denial.sh"
  } >"$work_dir/16-binary-authorization.txt" 2>&1
else
  global_hardening_outputs="$(terraform -chdir=infra/10-global output -json)"
  cluster_hardening_outputs="$(terraform -chdir=infra/20-cluster output -json)"
  jq -e '
    (.binary_authorization_enabled.value == false) and
    (.binary_authorization_policy_id.value == null)
  ' <<<"$global_hardening_outputs" >/dev/null \
    || fail "Binary Authorization disabled-state global outputs are invalid"
  jq -e '.binary_authorization_enabled.value == false' \
    <<<"$cluster_hardening_outputs" >/dev/null \
    || fail "Binary Authorization disabled-state cluster output is invalid"

  for cluster_spec in 'gke-risk-usc1 us-central1' 'gke-risk-use4 us-east4'; do
    read -r cluster_name cluster_location <<<"$cluster_spec"
    cluster_json="$(
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
        --account="$expected_account" \
        --project="$PROJECT_ID" \
        container clusters describe "$cluster_name" \
        --location="$cluster_location" \
        --format=json
    )"
    jq -e '(.binaryAuthorization.evaluationMode // "DISABLED") == "DISABLED"' \
      <<<"$cluster_json" >/dev/null \
      || fail "Binary Authorization is unexpectedly enabled on $cluster_name"
  done

  {
    printf 'feature=Binary Authorization\n'
    printf 'implementation=Terraform feature flag ENABLE_BINARY_AUTHORIZATION\n'
    printf 'live_state=disabled\n'
    printf 'cost_state=no cluster enforcement enabled\n'
    printf 'verification=both live clusters report Binary Authorization disabled\n'
  } >"$work_dir/16-binary-authorization.txt"
fi

expected_outputs=(
  01-budget.txt 01-budget.png
  02-clusters.txt 03-negs.txt 04-backend-health-before.txt
  05-public-endpoint.json 06-logging.txt 06-logging.png
  07-bigquery.txt 07-bigquery-schema.json 07-bigquery.png
  07-bigquery-error-rate.csv
  07-bigquery-latency-percentiles.csv
  07-bigquery-trace-join.csv
  07-bigquery-regional-traffic.csv
  07-bigquery-auth-rejections.csv
  14-service-auth.txt
  15-cloud-armor.txt
  16-binary-authorization.txt
  17-team-isolation.txt
)
for output_name in "${expected_outputs[@]}"; do
  source_file="$work_dir/$output_name"
  [[ -s "$source_file" ]] || fail "evidence output $output_name was not generated"
done
for output_name in "${expected_outputs[@]}"; do
  mv -f -- "$work_dir/$output_name" "$evidence_dir/$output_name"
done

printf 'Captured non-secret release evidence for App A %s / App B %s, including team isolation.\n' \
  "$app_a_sha" "$app_b_sha"

#!/usr/bin/env bash
set -Eeuo pipefail
set +x

mode="${1:-status}"
case "$mode" in
  static | start | status | verify | cleanup) ;;
  *)
    printf 'Usage: %s static\n' "$0" >&2
    printf '       %s {start|status|verify|cleanup} FULL_GIT_SHA\n' "$0" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
namespace="currency-observability"
job="currency-grafana-evidence"
grafana_ksa="currency-grafana"
local_port="${GRAFANA_LOCAL_PORT:-33000}"
runtime_root="$repo_root/.tmp/gke-grafana-evidence"
state_file="$runtime_root/state.json"
kubeconfig="$runtime_root/kubeconfig"
rendered_manifest="$runtime_root/rendered.yaml"
port_forward_log="$runtime_root/port-forward.log"
started_resources=0
release_sha="${2:-${GRAFANA_IMAGE_TAG:-}}"

fail() {
  printf 'gke-grafana-evidence: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

cli_path() {
  case "$(uname -s)" in
    MINGW* | MSYS*) cygpath -w "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

render_manifest() {
  local image_reference="$1" source_sha="$2" destination="$3"
  [[ "$image_reference" =~ ^us-central1-docker\.pkg\.dev/schwab-assessment-gke/risk/grafana-evidence@sha256:[0-9a-f]{64}$ ]] \
    || fail "Grafana render requires the exact Artifact Registry digest path"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] \
    || fail "Grafana render requires a full release Git SHA"
  kubectl kustomize "$repo_root/observability/grafana" \
    | sed \
      -e "s|GRAFANA_IMAGE_REFERENCE|$image_reference|g" \
      -e "s|RELEASE_SHA_VALUE|$source_sha|g" \
    >"$destination"
  ! grep -Eq 'GRAFANA_IMAGE_REFERENCE|RELEASE_SHA_VALUE' "$destination" \
    || fail "Grafana manifest contains an unresolved release placeholder"
  [[ "$(grep -Fc "image: $image_reference" "$destination")" == "1" ]] \
    || fail "Grafana manifest must contain exactly one resolved digest image"
}

render_static() {
  local scratch rendered fixture_sha fixture_digest fixture_image
  local dockerfile="$repo_root/observability/grafana/Dockerfile"
  local build_config="$repo_root/cloudbuild-grafana.yaml"
  for command_name in git grep jq kubectl mktemp sed; do
    require_command "$command_name"
  done
  mkdir -p "$repo_root/.tmp"
  scratch="$(mktemp -d "$repo_root/.tmp/grafana-static.XXXXXX")"
  rendered="$scratch/rendered.yaml"
  trap 'rm -rf -- "$scratch"' RETURN
  git check-ignore --quiet -- "$scratch" \
    || fail "static render directory must be ignored"
  fixture_sha="1111111111111111111111111111111111111111"
  fixture_digest="sha256:$(printf '2%.0s' {1..64})"
  fixture_image="us-central1-docker.pkg.dev/$expected_project/risk/grafana-evidence@$fixture_digest"
  render_manifest "$fixture_image" "$fixture_sha" "$rendered"

  grep -Fq 'grafana/grafana:13.1.0@sha256:121a7a9ece6dc10b969f1f96eed64b4f07dfac0d0b8abc070f7cb83bbde86f63' \
    "$dockerfile" || fail "Grafana build base must remain digest pinned"
  grep -Fq 'GRAFANA_BIGQUERY_VERSION=3.2.0' "$dockerfile" \
    || fail "Grafana BigQuery build version changed"
  grep -Fq 'GRAFANA_BIGQUERY_SHA256=6b1c2c457f4131608874553e14eab5c12f356f66114b2facea6d81bd323a74ea' \
    "$dockerfile" || fail "Grafana BigQuery archive checksum changed"
  grep -Fq 'sha256sum -c -' "$dockerfile" \
    || fail "Grafana plugin download must be checksum verified"
  grep -Fq 'GF_PATHS_PLUGINS=/usr/share/grafana/preinstalled-plugins' \
    "$dockerfile" || fail "Grafana must load the baked plugin directory"
  grep -Fq '${_REPOSITORY}/grafana-evidence:${_GIT_SHA}' "$build_config" \
    || fail "Grafana Cloud Build output must use an immutable full-SHA tag"
  grep -Fq -- '--ignore-unfixed' "$build_config" \
    || fail "Grafana Cloud Build must retain the fixed-vulnerability gate"

  [[ "$(grep -c '^kind: Job$' "$rendered")" == "1" ]] \
    || fail "Grafana render must contain exactly one Job"
  [[ "$(grep -c '^kind: ConfigMap$' "$rendered")" == "2" ]] \
    || fail "Grafana render must contain exactly two ConfigMaps"
  [[ "$(grep -Ec '^kind: (Service|Secret|Ingress|PersistentVolumeClaim|Deployment|StatefulSet|DaemonSet)$' "$rendered" || true)" == "0" ]] \
    || fail "Grafana evidence must not expose or persist a standing workload"
  [[ "$(grep -c '^  namespace: currency-observability$' "$rendered")" == "3" ]] \
    || fail "every Grafana object must use currency-observability"
  grep -Fq 'name: currency-grafana-evidence' "$rendered" \
    || fail "Grafana Job name changed"
  grep -Fq 'activeDeadlineSeconds: 3600' "$rendered" \
    || fail "Grafana Job must stop within one hour"
  grep -Fq 'ttlSecondsAfterFinished: 60' "$rendered" \
    || fail "Grafana Job must be garbage-collected"
  grep -Fq 'serviceAccountName: currency-grafana' "$rendered" \
    || fail "Grafana Job must use its dedicated KSA"
  grep -Fq 'automountServiceAccountToken: false' "$rendered" \
    || fail "Grafana Job must not mount a Kubernetes API token"
  grep -Fq "image: $fixture_image" "$rendered" \
    || fail "Grafana runtime image must use the resolved Artifact Registry digest"
  grep -Fq "value: $fixture_sha" "$rendered" \
    || fail "Grafana runtime manifest must retain its source SHA"
  ! grep -Eq 'GF_PLUGINS_PREINSTALL(_SYNC)?' "$rendered" \
    || fail "Grafana must not download plugins at runtime"
  grep -Fq 'readOnlyRootFilesystem: true' "$rendered" \
    || fail "Grafana root filesystem must remain read-only"
  grep -Fq 'runAsGroup: 472' "$rendered" \
    || fail "Grafana must not run with root group ownership"
  grep -Fq 'fsGroup: 472' "$rendered" \
    || fail "Grafana writable emptyDir ownership must remain non-root"
  grep -Fq 'allowPrivilegeEscalation: false' "$rendered" \
    || fail "Grafana privilege escalation must remain disabled"
  grep -Fq 'requests:' "$rendered" && grep -Fq 'cpu: 250m' "$rendered" \
    || fail "Grafana CPU request must remain cost bounded"
  grep -Fq 'memory: 512Mi' "$rendered" \
    || fail "Grafana memory request must remain cost bounded"
  grep -Fq 'ephemeral-storage: 256Mi' "$rendered" \
    || fail "Grafana ephemeral-storage request must remain bounded"
  grep -Fq 'ephemeral-storage: 640Mi' "$rendered" \
    || fail "Grafana ephemeral-storage limit must remain bounded"
  grep -Fq 'sizeLimit: 512Mi' "$rendered" \
    || fail "Grafana data emptyDir must remain bounded"
  grep -Fq 'sizeLimit: 128Mi' "$rendered" \
    || fail "Grafana temporary emptyDir must remain bounded"
  grep -Fq 'value: "true"' "$rendered" \
    || fail "Grafana anonymous loopback mode is missing"
  grep -Fq 'value: http://127.0.0.1:33000' "$rendered" \
    || fail "Grafana root URL must remain loopback-only"

  bash "$repo_root/scripts/verify-grafana.sh" --static
  printf '%s\n' \
    'Grafana GKE contract: PASS (one deadline-bounded Job, two ConfigMaps, no Service/Ingress/Secret/PVC, operator loopback access only).'
  trap - RETURN
  rm -rf -- "$scratch"
}

[[ "$mode" == "static" ]] && {
  [[ $# -eq 1 ]] || fail "static mode does not accept a release SHA"
  render_static
  exit 0
}

for command_name in curl gcloud git jq kubectl timeout; do
  require_command "$command_name"
done
[[ $# -eq 2 ]] || fail "live modes require one explicit full Git SHA"
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "GRAFANA_IMAGE_TAG must be a full lowercase 40-character Git SHA"
if [[ "$mode" != "cleanup" ]]; then
  git cat-file -e "$release_sha^{commit}" 2>/dev/null \
    || fail "$release_sha is not a local commit"
fi
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"

: "${PROJECT_ID:=$expected_project}"
: "${GCLOUD_CONFIGURATION:=$expected_configuration}"
[[ "$PROJECT_ID" == "$expected_project" ]] || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"
case "$local_port" in
  '' | *[!0-9]*) fail "GRAFANA_LOCAL_PORT must be numeric" ;;
esac
[[ "$local_port" == "33000" ]] \
  || fail "GRAFANA_LOCAL_PORT is fixed at 33000 to match the provisioned root URL"
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_ACCESS_TOKEN GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_KEYFILE_JSON \
  GOOGLE_CREDENTIALS GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] || fail "$override_name must be unset"
done
for auth_property in \
  auth/access_token_file auth/credential_file_override \
  auth/impersonate_service_account; do
  auth_value="$(gcloud --configuration="$GCLOUD_CONFIGURATION" \
    config get-value "$auth_property" 2>/dev/null)"
  [[ -z "$auth_value" || "$auth_value" == "(unset)" ]] \
    || fail "$auth_property must be unset in the named gcloud configuration"
done
active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected project $PROJECT_ID, found ${configured_project:-<none>}"
export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

context="${GRAFANA_CONTEXT:-gke-risk-usc1}"
case "$context" in
  gke-risk-usc1) cluster="gke-risk-usc1"; region="us-central1" ;;
  gke-risk-use4) cluster="gke-risk-use4"; region="us-east4" ;;
  *) fail "GRAFANA_CONTEXT must be gke-risk-usc1 or gke-risk-use4" ;;
esac

mkdir -p "$runtime_root"
git check-ignore --quiet -- "$runtime_root" || fail "runtime directory must be ignored"
chmod 700 "$runtime_root" 2>/dev/null || true
kubeconfig_cli="$(cli_path "$kubeconfig")"

prepare_kubeconfig() {
  rm -f -- "$kubeconfig"
  printf '%s\n' 'apiVersion: v1' 'kind: Config' 'preferences: {}' \
    'clusters: []' 'contexts: []' 'users: []' >"$kubeconfig"
  chmod 600 "$kubeconfig" 2>/dev/null || true
  KUBECONFIG="$kubeconfig_cli" timeout --foreground --signal=INT 2m \
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      container clusters get-credentials "$cluster" --region="$region" >/dev/null
  source_context="$(KUBECONFIG="$kubeconfig_cli" kubectl config current-context | tr -d '\r')"
  if [[ "$source_context" != "$context" ]]; then
    KUBECONFIG="$kubeconfig_cli" kubectl config rename-context "$source_context" "$context" >/dev/null
  fi
  [[ "$(KUBECONFIG="$kubeconfig_cli" kubectl config get-contexts -o name | tr -d '\r')" == "$context" ]] \
    || fail "isolated kubeconfig contains an unexpected context"
}

kube() {
  KUBECONFIG="$kubeconfig_cli" kubectl --context="$context" \
    --namespace="$namespace" --request-timeout=30s "$@"
}

assert_owned_object() {
  local resource="$1" name="$2" json
  json="$(kube get "$resource" "$name" -o json 2>/dev/null)" || return 1
  jq -e '.metadata.labels["app.kubernetes.io/managed-by"] == "evidence-workflow" and
    .metadata.labels["app.kubernetes.io/name"] == "currency-grafana-evidence"' \
    <<<"$json" >/dev/null || fail "refusing to manage unowned $resource/$name"
}

verify_installed_plugin() {
  local pod_name="$1" plugins
  plugins="$(kube exec "$pod_name" -- \
    grafana cli --pluginsDir /usr/share/grafana/preinstalled-plugins plugins ls 2>&1)" \
    || fail "could not inspect the running Grafana plugin inventory"
  grep -Eq 'grafana-bigquery-datasource[[:space:]@]+3\.2\.0' <<<"$plugins" \
    || fail "running Grafana does not contain pinned BigQuery plugin 3.2.0"
}

stop_port_forward() {
  local pid="" args=""
  [[ -f "$state_file" ]] && pid="$(jq -r '.portForwardPid // empty' "$state_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "refusing invalid port-forward PID in runtime state"
  if kill -0 "$pid" 2>/dev/null; then
    case "$(uname -s)" in
      MINGW* | MSYS*)
        args="$(powershell.exe -NoProfile -NonInteractive -Command \
          "(Get-CimInstance Win32_Process -Filter 'ProcessId = $pid').CommandLine" \
          2>/dev/null | tr -d '\r' || true)"
        ;;
      *) args="$(ps -p "$pid" -o args= 2>/dev/null || true)" ;;
    esac
    if [[ "$args" == *kubectl*port-forward*"$local_port:3000"* ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    else
      printf 'Not killing PID %s because it is not the owned Grafana port-forward.\n' "$pid" >&2
    fi
  fi
}

cleanup_live() {
  local name
  stop_port_forward
  if kube get job "$job" >/dev/null 2>&1; then
    assert_owned_object job "$job"
    kube delete job "$job" --wait=true >/dev/null
  fi
  for name in currency-grafana-provisioning currency-grafana-dashboard; do
    if kube get configmap "$name" >/dev/null 2>&1; then
      assert_owned_object configmap "$name"
      kube delete configmap "$name" --wait=true >/dev/null
    fi
  done
  rm -f -- "$state_file" "$rendered_manifest" "$port_forward_log" "$kubeconfig"
  printf '%s\n' 'Grafana evidence workload, ConfigMaps, port-forward, and local runtime state removed.'
}

if [[ "$mode" != "start" && -f "$state_file" ]]; then
  state_context="$(jq -r '.context // empty' "$state_file")"
  state_port="$(jq -r '.localPort // empty' "$state_file")"
  state_release_sha="$(jq -r '.releaseSha // empty' "$state_file")"
  state_image_digest="$(jq -r '.imageDigest // empty' "$state_file")"
  state_image_reference="$(jq -r '.imageReference // empty' "$state_file")"
  [[ "$state_context" == "$context" ]] \
    || fail "state belongs to $state_context; set GRAFANA_CONTEXT accordingly"
  [[ "$state_port" == "$local_port" ]] \
    || fail "state uses port $state_port; set GRAFANA_LOCAL_PORT accordingly"
  [[ "$state_release_sha" == "$release_sha" ]] \
    || fail "state belongs to release ${state_release_sha:-<missing>}; use its exact GRAFANA_IMAGE_TAG"
  [[ "$state_image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "state contains an invalid Grafana image digest"
  [[ "$state_image_reference" == "us-central1-docker.pkg.dev/$PROJECT_ID/risk/grafana-evidence@$state_image_digest" ]] \
    || fail "state contains an invalid Grafana image reference"
  if [[ "$mode" != "cleanup" ]]; then
    current_image_digest="$(VERIFY_IMAGE_FORMAT=digest \
      bash "$repo_root/scripts/verify-image.sh" grafana-evidence "$release_sha")"
    [[ "$current_image_digest" == "$state_image_digest" ]] \
      || fail "the immutable Grafana tag no longer resolves to the session digest"
  fi
fi
prepare_kubeconfig

if [[ "$mode" == "cleanup" ]]; then
  cleanup_live
  exit 0
fi

validate_platform() {
  local namespace_json sa_json quota_json policy_json
  namespace_json="$(kube get namespace "$namespace" -o json)"
  jq -e '.metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted" and
    .metadata.labels["pod-security.kubernetes.io/audit"] == "restricted" and
    .metadata.labels["pod-security.kubernetes.io/warn"] == "restricted"' \
    <<<"$namespace_json" >/dev/null || fail "observability namespace Pod Security labels changed"
  sa_json="$(kube get serviceaccount "$grafana_ksa" -o json)"
  jq -e --arg gsa "grafana-reader@$PROJECT_ID.iam.gserviceaccount.com" '
    .automountServiceAccountToken == false and
    .metadata.annotations["iam.gke.io/gcp-service-account"] == $gsa
  ' <<<"$sa_json" >/dev/null || fail "Grafana KSA/GSA mapping changed"
  quota_json="$(kube get resourcequota evidence-capacity -o json)"
  jq -e '.spec.hard.services == "0" and .spec.hard.secrets == "0" and
    .spec.hard.pods == "1" and .spec.hard["count/jobs.batch"] == "1" and
    .spec.hard["requests.cpu"] == "250m" and .spec.hard["requests.memory"] == "512Mi" and
    .spec.hard["requests.ephemeral-storage"] == "256Mi" and
    .spec.hard["limits.ephemeral-storage"] == "640Mi"' \
    <<<"$quota_json" >/dev/null || fail "Grafana evidence quota changed"
  policy_json="$(kube get networkpolicy default-deny-ingress -o json)"
  jq -e '.spec.podSelector == {} and .spec.policyTypes == ["Ingress"] and
    ((.spec.ingress // []) == [])' <<<"$policy_json" >/dev/null \
    || fail "Grafana ingress isolation changed"
}

validate_platform

if [[ "$mode" == "start" ]]; then
  render_static
  [[ ! -f "$state_file" ]] \
    || fail "an evidence session already exists; inspect status or run cleanup"
  for object in "job/$job" \
    'configmap/currency-grafana-provisioning' 'configmap/currency-grafana-dashboard'; do
    if kube get "$object" >/dev/null 2>&1; then
      fail "$object already exists; run cleanup only after confirming it belongs to this workflow"
    fi
  done
  image_digest="$(VERIFY_IMAGE_FORMAT=digest \
    bash "$repo_root/scripts/verify-image.sh" grafana-evidence "$release_sha")"
  [[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "Grafana image tag did not resolve to one immutable digest"
  image_reference="us-central1-docker.pkg.dev/$PROJECT_ID/risk/grafana-evidence@$image_digest"
  render_manifest "$image_reference" "$release_sha" "$rendered_manifest"
  jq -n \
    --arg context "$context" --arg region "$region" --arg port "$local_port" \
    --arg release_sha "$release_sha" --arg image_digest "$image_digest" \
    --arg image_reference "$image_reference" \
    '{context:$context,region:$region,localPort:$port,releaseSha:$release_sha,
      imageDigest:$image_digest,imageReference:$image_reference}' >"$state_file"
  trap 'exit_code=$?; trap - EXIT INT TERM; if ((started_resources == 1)); then cleanup_live || true; fi; exit "$exit_code"' EXIT INT TERM
  started_resources=1
  kube apply -f "$rendered_manifest" >/dev/null
  kube wait --for=condition=Ready \
    --selector="app.kubernetes.io/name=currency-grafana-evidence" \
    pod --timeout=10m >/dev/null
  pod="$(kube get pods --selector="app.kubernetes.io/name=currency-grafana-evidence" \
    -o json | jq -r 'select((.items | length) == 1) | .items[0].metadata.name')"
  [[ -n "$pod" && "$pod" != "null" ]] || fail "expected exactly one Grafana Pod"
  pod_json="$(kube get pod "$pod" -o json)"
  jq -e --arg image "$image_reference" --arg digest "$image_digest" '
    (.spec.containers | length) == 1 and .spec.containers[0].image == $image and
    any(.status.containerStatuses[]?;
      .name == "grafana" and (.imageID | endswith("@" + $digest)))
  ' <<<"$pod_json" >/dev/null \
    || fail "running Grafana Pod does not use the reviewed image digest"
  verify_installed_plugin "$pod"
  nohup env KUBECONFIG="$kubeconfig_cli" \
    kubectl --context="$context" --namespace="$namespace" \
      port-forward --address=127.0.0.1 "pod/$pod" "$local_port:3000" \
      >"$port_forward_log" 2>&1 </dev/null &
  port_forward_pid=$!
  jq --arg pod "$pod" --argjson pid "$port_forward_pid" \
    '. + {pod:$pod,portForwardPid:$pid}' "$state_file" >"$state_file.tmp"
  mv -f -- "$state_file.tmp" "$state_file"
  for _ in $(seq 1 60); do
    curl --silent --show-error --fail --max-time 2 \
      "http://127.0.0.1:$local_port/api/health" >/dev/null 2>&1 && break
    kill -0 "$port_forward_pid" 2>/dev/null || {
      sed -n '1,80p' "$port_forward_log" >&2
      fail "Grafana port-forward exited"
    }
    sleep 1
  done
  curl --silent --show-error --fail --max-time 5 \
    "http://127.0.0.1:$local_port/api/health" >/dev/null \
    || fail "Grafana did not become reachable on loopback"
  GRAFANA_URL="http://127.0.0.1:$local_port" GRAFANA_ANONYMOUS_LOOPBACK=1 \
    bash "$repo_root/scripts/verify-grafana.sh"
  trap - EXIT INT TERM
  printf 'GKE-hosted Grafana is verified at http://127.0.0.1:%s (Pod %s, %s).\n' \
    "$local_port" "$pod" "$region"
  printf '%s\n' \
    "It has no Service or public endpoint. Capture the screenshot, then run: make cleanup-gke-grafana GRAFANA_IMAGE_TAG=$release_sha"
  printf '%s\n' \
    'The Job forcibly stops within one hour. At current us-central1 list rates, the declared 250m CPU/512Mi request is about $0.014 for one hour, excluding network, storage, tax, and any Autopilot request adjustment.'
  exit 0
fi

[[ -f "$state_file" ]] || fail "no active evidence state; run start first"
pod="$(jq -r '.pod // empty' "$state_file")"
[[ -n "$pod" ]] || fail "evidence state has no Pod"
assert_owned_object job "$job"
pod_json="$(kube get pod "$pod" -o json)"
jq -e \
  --arg image "$(jq -r '.imageReference // empty' "$state_file")" \
  --arg digest "$(jq -r '.imageDigest // empty' "$state_file")" \
  '.metadata.labels["app.kubernetes.io/managed-by"] == "evidence-workflow" and
  .status.phase == "Running" and
  any(.status.conditions[]?; .type == "Ready" and .status == "True") and
  (.spec.containers | length) == 1 and .spec.containers[0].image == $image and
  any(.status.containerStatuses[]?;
    .name == "grafana" and (.imageID | endswith("@" + $digest)))' \
  <<<"$pod_json" >/dev/null || fail "Grafana evidence Pod is not Ready"
verify_installed_plugin "$pod"
curl --silent --show-error --fail --max-time 5 \
  "http://127.0.0.1:$local_port/api/health" >/dev/null \
  || fail "Grafana loopback endpoint is unavailable; rerun start after cleanup"

if [[ "$mode" == "verify" ]]; then
  GRAFANA_URL="http://127.0.0.1:$local_port" GRAFANA_ANONYMOUS_LOOPBACK=1 \
    bash "$repo_root/scripts/verify-grafana.sh"
  printf '%s\n' 'GKE-hosted Grafana live gate: PASS.'
else
  printf 'Grafana evidence session: READY at http://127.0.0.1:%s (%s/%s).\n' \
    "$local_port" "$context" "$pod"
fi

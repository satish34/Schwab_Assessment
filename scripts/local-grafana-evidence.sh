#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

case "$(uname -s)" in
  MINGW*|MSYS*)
    if [[ -n "${LOCALAPPDATA:-}" ]]; then
      winget_links="$(cygpath -u "$LOCALAPPDATA")/Microsoft/WinGet/Links"
      [[ ! -d "$winget_links" ]] || export PATH="$winget_links:$PATH"
    fi
    ;;
esac

action="${1:-status}"
expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
grafana_reader="grafana-reader@$expected_project.iam.gserviceaccount.com"
grafana_image="grafana/grafana:13.1.3-slim@sha256:2ae4278f55179f275614c076ac69cacc65f3f4748edf3edc19aa2ac8204caeab"
metadata_image="python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df"
bigquery_plugin="grafana-bigquery-datasource@3.3.1"
grafana_container="schwab-grafana-evidence"
metadata_container="schwab-grafana-metadata"
egress_network="schwab-grafana-egress"
metadata_network="schwab-grafana-metadata"
metadata_subnet="169.254.169.0/24"
metadata_ip="169.254.169.254"
owner_label="com.schwab-assessment.owner=grafana-evidence"
runtime_root="$repo_root/.tmp"
session_dir="$runtime_root/grafana-evidence"
grafana_data="$session_dir/grafana-data"
handoff_file="$session_dir/handoff.env"
admin_password_file="$session_dir/admin-password"
secret_key_file="$session_dir/grafana-secret-key"
gcp_token_file="$session_dir/gcp-access-token"
metadata_stub="$repo_root/scripts/grafana-metadata-stub.py"
port="${GRAFANA_EVIDENCE_PORT:-33000}"
session_ttl_seconds="${GRAFANA_EVIDENCE_TTL_SECONDS:-3600}"
grafana_url="http://127.0.0.1:$port"
dashboard_url="$grafana_url/d/schwab-currency-cells/schwab-assessment-currency-rate-cells?orgId=1&from=now-24h&to=now"
keep_running=0
cleanup_active=0

fail() {
  printf 'local-grafana-evidence: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

docker_host_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -am "$path"
  else
    printf '%s\n' "$path"
  fi
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
}

require_container_owner() {
  local name="$1"
  local actual
  actual="$(docker container inspect --format '{{index .Config.Labels "com.schwab-assessment.owner"}}' "$name")"
  [[ "$actual" == "grafana-evidence" ]] \
    || fail "refusing to touch container $name without the expected ownership label"
}

require_network_owner() {
  local name="$1"
  local actual
  actual="$(docker network inspect --format '{{index .Labels "com.schwab-assessment.owner"}}' "$name")"
  [[ "$actual" == "grafana-evidence" ]] \
    || fail "refusing to touch network $name without the expected ownership label"
}

remove_runtime_dir() {
  [[ "$runtime_root" == "$repo_root/.tmp" ]] \
    || fail "runtime root escaped the repository .tmp directory"
  [[ "$session_dir" == "$repo_root/.tmp/grafana-evidence" ]] \
    || fail "session directory escaped the approved runtime path"
  if [[ -e "$session_dir" ]]; then
    rm -rf -- "$session_dir"
  fi
}

cleanup() {
  local failed=0
  ((cleanup_active == 0)) || return 0
  cleanup_active=1

  for name in "$grafana_container" "$metadata_container"; do
    if container_exists "$name"; then
      require_container_owner "$name"
      timeout --foreground --signal=TERM --kill-after=5s 25s \
        docker container rm --force "$name" >/dev/null || failed=1
    fi
  done
  for name in "$metadata_network" "$egress_network"; do
    if network_exists "$name"; then
      require_network_owner "$name"
      timeout --foreground --signal=TERM --kill-after=5s 20s \
        docker network rm "$name" >/dev/null || failed=1
    fi
  done
  remove_runtime_dir
  cleanup_active=0
  ((failed == 0)) || fail "one or more disposable Docker resources could not be removed"
}

cleanup_on_error() {
  local exit_code=$?
  if ((keep_running == 0)); then
    cleanup || true
  fi
  exit "$exit_code"
}

run_static() {
  require_command bash
  require_command docker
  require_command git
  require_command python
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) \
    || fail "GRAFANA_EVIDENCE_PORT must be an unprivileged TCP port"
  [[ "$session_ttl_seconds" =~ ^[0-9]+$ ]] \
    && ((session_ttl_seconds >= 900 && session_ttl_seconds <= 3600)) \
    || fail "GRAFANA_EVIDENCE_TTL_SECONDS must be between 900 and 3600"
  [[ "$grafana_image" == grafana/grafana:13.1.3-slim@sha256:* ]] \
    || fail "Grafana must stay pinned to 13.1.3 and an immutable digest"
  [[ "$metadata_image" == *@sha256:* && "$metadata_image" != *:latest* ]] \
    || fail "the metadata helper image must use an immutable non-latest reference"
  [[ "$bigquery_plugin" == "grafana-bigquery-datasource@3.3.1" ]] \
    || fail "the BigQuery plugin must stay pinned to 3.3.1"
  [[ "$metadata_subnet" == "169.254.169.0/24" \
    && "$metadata_ip" == "169.254.169.254" ]] \
    || fail "the metadata compatibility network must retain the documented metadata address"
  docker image inspect "$grafana_image" >/dev/null 2>&1 \
    || fail "the pinned Grafana 13.1.3 image is not local; pull it explicitly before start"
  docker image inspect "$metadata_image" >/dev/null 2>&1 \
    || fail "the pinned metadata helper image is not local; pull it explicitly before start"
  git check-ignore --quiet -- "$session_dir/fixture" \
    || fail "the Grafana evidence session directory must remain ignored"
  bash -n "$repo_root/scripts/local-grafana-evidence.sh"
  METADATA_PROJECT_ID="$expected_project" \
    METADATA_PROJECT_NUMBER="123456789" \
    METADATA_SERVICE_ACCOUNT="$grafana_reader" \
    python "$metadata_stub" --self-test
  bash "$repo_root/scripts/verify-grafana.sh" --static
  printf 'Verified the bounded local Grafana evidence tooling without credentials.\n'
}

show_status() {
  local grafana_state="absent"
  local metadata_state="absent"
  if container_exists "$grafana_container"; then
    require_container_owner "$grafana_container"
    grafana_state="$(docker container inspect --format '{{.State.Status}}' "$grafana_container")"
  fi
  if container_exists "$metadata_container"; then
    require_container_owner "$metadata_container"
    metadata_state="$(docker container inspect --format '{{.State.Status}}' "$metadata_container")"
  fi
  printf 'grafana_container=%s\nmetadata_container=%s\n' "$grafana_state" "$metadata_state"
  if [[ -f "$handoff_file" ]]; then
    grep -E '^(GRAFANA_URL|GRAFANA_DASHBOARD_URL|GRAFANA_READY|GRAFANA_EXPIRES_AT)=' \
      "$handoff_file"
  fi
}

wait_for_grafana() {
  local deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    if curl --silent --show-error --fail --max-time 5 \
      "$grafana_url/api/health" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(docker container inspect --format '{{.State.Running}}' "$grafana_container")" != "true" ]]; then
      fail "Grafana exited before becoming healthy; inspect with docker logs $grafana_container"
    fi
    sleep 2
  done
  fail "Grafana did not become healthy within five minutes"
}

verify_live() {
  container_exists "$grafana_container" \
    || fail "the disposable Grafana container is absent; run start first"
  require_container_owner "$grafana_container"
  [[ "$(docker container inspect --format '{{.State.Running}}' "$grafana_container")" == "true" ]] \
    || fail "the disposable Grafana container is not running"
  GRAFANA_URL="$grafana_url" GRAFANA_ANONYMOUS_LOOPBACK=1 \
    bash "$repo_root/scripts/verify-grafana.sh"
}

start() {
  run_static
  for command_name in curl gcloud jq openssl timeout; do
    require_command "$command_name"
  done
  for name in "$grafana_container" "$metadata_container"; do
    container_exists "$name" && fail "$name already exists; run cleanup first"
  done
  for name in "$egress_network" "$metadata_network"; do
    network_exists "$name" && fail "$name already exists; run cleanup first"
  done
  [[ ! -e "$session_dir" ]] || fail "$session_dir already exists; run cleanup first"

  : "${PROJECT_ID:=$expected_project}"
  : "${GCLOUD_CONFIGURATION:=$expected_configuration}"
  [[ "$PROJECT_ID" == "$expected_project" ]] || fail "expected project $expected_project"
  [[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
    || fail "expected gcloud configuration $expected_configuration"
  for override_name in \
    CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
    CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
    GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
    [[ -z "${!override_name:-}" ]] || fail "$override_name must be unset"
  done
  local active_account configured_project project_number
  active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
  configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
  [[ "$active_account" == "$expected_account" && "$configured_project" == "$PROJECT_ID" ]] \
    || fail "the named gcloud configuration must target the frozen account and project"
  project_number="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" --account="$expected_account" \
      --project="$PROJECT_ID" projects describe "$PROJECT_ID" --format='value(projectNumber)'
  )"
  [[ "$project_number" =~ ^[0-9]+$ ]] || fail "could not resolve the numeric project ID"
  [[ "$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" --account="$expected_account" \
      --project="$PROJECT_ID" services list --enabled \
      --filter='name:iamcredentials.googleapis.com' --format='value(config.name)'
  )" == "iamcredentials.googleapis.com" ]] \
    || fail "IAM Service Account Credentials API must be enabled by Terraform before token minting"

  umask 077
  mkdir -p "$grafana_data/dashboards"
  git check-ignore --quiet -- "$session_dir" \
    || fail "the runtime credential directory is not ignored"
  openssl rand -hex 24 >"$admin_password_file"
  openssl rand -hex 32 >"$secret_key_file"

  trap cleanup_on_error EXIT INT TERM
  docker network create --driver bridge --label "$owner_label" \
    "$egress_network" >/dev/null
  docker network create --driver bridge --internal \
    --subnet "$metadata_subnet" --label "$owner_label" \
    "$metadata_network" >/dev/null

  local expiry_epoch metadata_stub_host metadata_id token_probe
  gcloud --configuration="$GCLOUD_CONFIGURATION" --account="$expected_account" \
    --project="$PROJECT_ID" auth print-access-token \
    --impersonate-service-account="$grafana_reader" \
    --lifetime="${session_ttl_seconds}s" >"$gcp_token_file"
  IFS= read -r token_probe <"$gcp_token_file"
  [[ ${#token_probe} -ge 20 ]] || fail "could not mint the short-lived Grafana reader token"
  unset token_probe
  expiry_epoch=$(( $(date -u '+%s') + session_ttl_seconds ))
  printf '%s\n' "$expiry_epoch" >>"$gcp_token_file"
  metadata_stub_host="$(docker_host_path "$metadata_stub")"
  local gcp_token_host
  gcp_token_host="$(docker_host_path "$gcp_token_file")"
  metadata_id="$(
    MSYS_NO_PATHCONV=1 docker run --detach \
          --name "$metadata_container" \
          --network "$metadata_network" \
          --ip "$metadata_ip" \
          --network-alias metadata.google.internal \
          --label "$owner_label" \
          --read-only \
          --tmpfs /tmp:rw,noexec,nosuid,size=16m \
          --cap-drop ALL \
          --security-opt no-new-privileges \
          --user 65532:65532 \
          --mount "type=bind,source=$metadata_stub_host,target=/opt/metadata-stub.py,readonly" \
          --mount "type=bind,source=$gcp_token_host,target=/run/secrets/gcp-token,readonly" \
          --env "METADATA_PROJECT_ID=$PROJECT_ID" \
          --env "METADATA_PROJECT_NUMBER=$project_number" \
          --env "METADATA_SERVICE_ACCOUNT=$grafana_reader" \
          --env METADATA_CREDENTIAL_FILE=/run/secrets/gcp-token \
          "$metadata_image" python /opt/metadata-stub.py
  )"
  [[ -n "$metadata_id" ]] || fail "the metadata stub did not start"

  local metadata_deadline=$((SECONDS + 30))
  while ((SECONDS < metadata_deadline)); do
    if docker exec "$metadata_container" python -c \
      'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1/healthz", timeout=2).read() == b"ok\n"' \
      >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  docker exec "$metadata_container" python -c \
    'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1/healthz", timeout=2).read() == b"ok\n"' \
    >/dev/null 2>&1 || fail "the internal metadata stub did not become healthy"

  local data_host admin_password_host secret_key_host datasources_host provider_host dashboard_host
  data_host="$(docker_host_path "$grafana_data")"
  admin_password_host="$(docker_host_path "$admin_password_file")"
  secret_key_host="$(docker_host_path "$secret_key_file")"
  datasources_host="$(docker_host_path "$repo_root/observability/grafana/provisioning/datasources.yaml")"
  provider_host="$(docker_host_path "$repo_root/observability/grafana/provisioning/dashboards.yaml")"
  dashboard_host="$(docker_host_path "$repo_root/observability/grafana/currency-dashboard.json")"

  MSYS_NO_PATHCONV=1 docker create \
    --name "$grafana_container" \
    --network "$egress_network" \
    --publish "127.0.0.1:$port:3000" \
    --label "$owner_label" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --mount "type=bind,source=$data_host,target=/var/lib/grafana" \
    --mount "type=bind,source=$admin_password_host,target=/run/secrets/admin-password,readonly" \
    --mount "type=bind,source=$secret_key_host,target=/run/secrets/secret-key,readonly" \
    --mount "type=bind,source=$datasources_host,target=/etc/grafana/provisioning/datasources/currency.yaml,readonly" \
    --mount "type=bind,source=$provider_host,target=/etc/grafana/provisioning/dashboards/currency.yaml,readonly" \
    --mount "type=bind,source=$dashboard_host,target=/var/lib/grafana/dashboards/currency-dashboard.json,readonly" \
    --env GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/admin-password \
    --env GF_SECURITY_SECRET_KEY__FILE=/run/secrets/secret-key \
    --env GF_AUTH_ANONYMOUS_ENABLED=true \
    --env GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
    --env GF_AUTH_ANONYMOUS_HIDE_VERSION=true \
    --env GF_USERS_ALLOW_SIGN_UP=false \
    --env GF_SERVER_DOMAIN=127.0.0.1 \
    --env "GF_SERVER_ROOT_URL=$grafana_url" \
    --env GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    --env GF_ANALYTICS_REPORTING_ENABLED=false \
    --env GF_PLUGINS_CHECK_FOR_UPDATES=false \
    --env GF_PLUGINS_PREINSTALL= \
    --env "GF_PLUGINS_PREINSTALL_SYNC=$bigquery_plugin" \
    --env GCE_METADATA_HOST=metadata.google.internal \
    --env NO_PROXY=metadata.google.internal,127.0.0.1,localhost \
    "$grafana_image" >/dev/null
  docker network connect "$metadata_network" "$grafana_container"
  docker start "$grafana_container" >/dev/null
  wait_for_grafana

  verify_live
  local expires_at
  expires_at="$(date -u -d "@$expiry_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
  {
    printf "GRAFANA_URL='%s'\n" "$grafana_url"
    printf "GRAFANA_DASHBOARD_URL='%s'\n" "$dashboard_url"
    printf 'GRAFANA_READY=true\n'
    printf 'GRAFANA_EXPIRES_AT=%s\n' "$expires_at"
  } >"$handoff_file"
  printf 'Local Grafana evidence runtime is ready at %s.\n' "$dashboard_url"
  printf 'Safe handoff: %s\n' "$handoff_file"
  printf 'Cleanup: bash scripts/local-grafana-evidence.sh cleanup\n'
  keep_running=1
  trap - EXIT INT TERM
}

case "$action" in
  static)
    [[ $# -eq 1 ]] || fail "usage: $0 static|start|status|verify|cleanup"
    run_static
    ;;
  start)
    [[ $# -eq 1 ]] || fail "usage: $0 static|start|status|verify|cleanup"
    start
    ;;
  status)
    [[ $# -eq 0 || $# -eq 1 ]] || fail "usage: $0 static|start|status|verify|cleanup"
    show_status
    ;;
  verify)
    [[ $# -eq 1 ]] || fail "usage: $0 static|start|status|verify|cleanup"
    verify_live
    ;;
  cleanup)
    [[ $# -eq 1 ]] || fail "usage: $0 static|start|status|verify|cleanup"
    cleanup
    printf 'Removed the disposable local Grafana evidence runtime.\n'
    ;;
  *)
    fail "usage: $0 static|start|status|verify|cleanup"
    ;;
esac

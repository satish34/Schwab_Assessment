#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

project_id="schwab-assessment-gke"
fixture_sha="0123456789abcdef0123456789abcdef01234567"
runtime_dir="$repo_root/.tmp"
work_dir=""

fail() {
  printf 'verify-kustomize-contracts: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/verify-kustomize.*)
        rm -f -- "$work_dir"/*.yaml
        rmdir -- "$work_dir" 2>/dev/null || true
        ;;
    esac
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

for command_name in awk grep kubectl sed; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done

require_fixed_count() {
  local file="$1"
  local expected="$2"
  local pattern="$3"
  local actual

  actual="$(grep -Fc -- "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]] \
    || fail "$file expected $expected occurrence(s) of: $pattern; found $actual"
}

require_regex_count() {
  local file="$1"
  local expected="$2"
  local pattern="$3"
  local actual

  actual="$(grep -Ec -- "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]] \
    || fail "$file expected $expected match(es) for: $pattern; found $actual"
}

require_overlay_zone() {
  local file="$1"
  local deployment="$2"
  local zone="$3"

  awk -v deployment="$deployment" -v zone="$zone" '
    $0 == "      name: " deployment { target = 1; next }
    target && /topology\.kubernetes\.io\/zone:/ {
      if ($2 == zone) found++
      target = 0
    }
    END { exit(found == 1 ? 0 : 1) }
  ' "$file" || fail "$deployment must be pinned exactly once to $zone in $file"
}

render() {
  local source="$1"
  local output="$2"

  kubectl kustomize "$source" \
    | sed -e "s/PROJECT_ID/$project_id/g" -e "s/GIT_SHA/$fixture_sha/g" \
    >"$output"
  ! grep -Eq \
    '(^|[^A-Z0-9_])PROJECT_ID([^A-Z0-9_]|$)|(^|[^A-Z0-9_])GIT_SHA([^A-Z0-9_]|$)|:latest([[:space:]]|$)' \
    "$output" \
    || fail "$source render contains a placeholder or latest tag"
}

mkdir -p "$runtime_dir"
work_dir="$(mktemp -d "$runtime_dir/verify-kustomize.XXXXXX")"

for region in us-central1 us-east4; do
  case "$region" in
    us-central1)
      expected_zones=(us-central1-f us-central1-b us-central1-c)
      ;;
    us-east4)
      expected_zones=(us-east4-a us-east4-b us-east4-c)
      ;;
    *) fail "unexpected region $region" ;;
  esac
  platform="$work_dir/$region-platform.yaml"
  app_a="$work_dir/$region-app-a.yaml"
  app_b="$work_dir/$region-app-b.yaml"
  aggregate="$work_dir/$region-aggregate.yaml"

  render "k8s/overlays/$region/platform" "$platform"
  render "k8s/overlays/$region/app-a" "$app_a"
  render "k8s/overlays/$region/app-b" "$app_b"
  render "k8s/overlays/$region" "$aggregate"

  require_overlay_zone \
    "k8s/overlays/$region/app-a/kustomization.yaml" app-a-gateway-a "${expected_zones[0]}"
  require_overlay_zone \
    "k8s/overlays/$region/app-a/kustomization.yaml" app-a-gateway-b "${expected_zones[1]}"
  require_overlay_zone \
    "k8s/overlays/$region/app-a/kustomization.yaml" app-a-gateway-c "${expected_zones[2]}"

  require_regex_count "$platform" 3 '^kind: Namespace$'
  require_regex_count "$platform" 3 '^kind: ConfigMap$'
  require_regex_count "$platform" 5 '^kind: NetworkPolicy$'
  require_regex_count "$platform" 3 '^kind: ResourceQuota$'
  require_regex_count "$platform" 2 '^kind: Role$'
  require_regex_count "$platform" 2 '^kind: RoleBinding$'
  require_regex_count "$platform" 2 '^kind: Service$'
  require_regex_count "$platform" 3 '^kind: ServiceAccount$'
  require_regex_count "$platform" 4 '^  SERVICE_(REGION|CLUSTER):'
  require_fixed_count "$platform" 0 'SERVICE_VERSION'
  for mode in enforce audit warn; do
    require_fixed_count \
      "$platform" 3 "pod-security.kubernetes.io/$mode: restricted"
  done
  require_fixed_count \
    "$platform" 1 "iam.gke.io/gcp-service-account: currency-app-a-caller@$project_id.iam.gserviceaccount.com"
  require_fixed_count \
    "$platform" 1 "iam.gke.io/gcp-service-account: currency-app-b-telemetry@$project_id.iam.gserviceaccount.com"
  require_fixed_count \
    "$platform" 1 "iam.gke.io/gcp-service-account: grafana-reader@$project_id.iam.gserviceaccount.com"
  require_fixed_count "$platform" 2 'name: currency-observability'
  require_fixed_count "$platform" 1 'name: currency-grafana'
  require_fixed_count "$platform" 1 'name: evidence-capacity'
  require_fixed_count \
    "$platform" 1 "name: currency-app-a-deployer@$project_id.iam.gserviceaccount.com"
  require_fixed_count \
    "$platform" 1 "name: currency-app-b-deployer@$project_id.iam.gserviceaccount.com"
  require_fixed_count "$platform" 0 'application-developer'
  require_fixed_count "$platform" 0 'currency-app-a-dev@'
  require_fixed_count "$platform" 0 'currency-app-b-dev@'

  require_regex_count "$app_a" 3 '^kind: Deployment$'
  require_regex_count "$app_a" 3 '^kind: HorizontalPodAutoscaler$'
  require_regex_count "$app_a" 1 '^kind: PodDisruptionBudget$'
  require_regex_count "$app_a" 0 '^kind: (ConfigMap|Namespace|NetworkPolicy|ResourceQuota|Role|RoleBinding|Secret|Service|ServiceAccount)$'
  require_fixed_count "$app_a" 3 'name: SERVICE_VERSION'
  require_fixed_count "$app_a" 3 "value: $fixture_sha"
  require_fixed_count "$app_a" 3 'name: APP_B_BASE_URL'
  require_fixed_count \
    "$app_a" 3 'value: http://app-b-engine.currency-app-b.svc.cluster.local:8080'
  require_fixed_count "$app_a" 3 'name: APP_B_AUTH_MODE'
  require_fixed_count "$app_a" 3 'value: google-id-token'
  require_fixed_count "$app_a" 3 'name: APP_B_TOKEN_AUDIENCE'
  require_fixed_count \
    "$app_a" 3 'value: https://app-b-engine.schwab-assessment.internal'
  require_fixed_count "$app_a" 3 'name: OTEL_TRACING_ENABLED'
  require_fixed_count "$app_a" 6 'value: "true"'
  require_fixed_count "$app_a" 3 'name: OTEL_TRACES_SAMPLER_ARG'
  require_fixed_count "$app_a" 3 'value: "0.1"'
  require_fixed_count "$app_a" 3 'name: CLOUD_PROFILER_ENABLED'
  require_regex_count "$app_a" 3 '^        topology.kubernetes.io/zone: '
  for zone in "${expected_zones[@]}"; do
    require_fixed_count "$app_a" 1 "topology.kubernetes.io/zone: $zone"
  done
  require_regex_count "$app_b" 1 '^kind: Deployment$'
  require_regex_count "$app_b" 1 '^kind: HorizontalPodAutoscaler$'
  require_regex_count "$app_b" 1 '^kind: PodDisruptionBudget$'
  require_regex_count "$app_b" 0 '^kind: (ConfigMap|Namespace|NetworkPolicy|ResourceQuota|Role|RoleBinding|Secret|Service|ServiceAccount)$'
  require_fixed_count "$app_b" 1 'name: SERVICE_VERSION'
  require_fixed_count "$app_b" 1 "value: $fixture_sha"
  require_fixed_count "$app_b" 1 'name: APP_B_AUTH_MODE'
  require_fixed_count "$app_b" 1 'value: google-id-token'
  require_fixed_count "$app_b" 1 'name: APP_A_IDENTITY_EMAIL'
  require_fixed_count \
    "$app_b" 1 "value: currency-app-a-caller@$project_id.iam.gserviceaccount.com"
  require_fixed_count "$app_b" 1 'name: OTEL_TRACES_EXPORTER'
  require_fixed_count "$app_b" 1 'value: otlp'
  require_fixed_count "$app_b" 1 'name: OTEL_EXPORTER_OTLP_ENDPOINT'
  require_fixed_count \
    "$app_b" 1 'value: https://telemetry.googleapis.com/v1/traces'
  require_fixed_count "$app_b" 1 'name: OTEL_EXPORTER_OTLP_PROTOCOL'
  require_fixed_count "$app_b" 1 'value: http/protobuf'

  require_fixed_count \
    "$aggregate" 3 "image: us-central1-docker.pkg.dev/$project_id/risk/app-a:$fixture_sha"
  require_fixed_count \
    "$aggregate" 1 "image: us-central1-docker.pkg.dev/$project_id/risk/app-b:$fixture_sha"
  require_fixed_count "$aggregate" 4 'name: SERVICE_VERSION'
  require_fixed_count "$aggregate" 4 "value: $fixture_sha"
  require_regex_count "$aggregate" 33 '^kind: '

  printf 'Verified independent and aggregate Kubernetes contracts for %s.\n' "$region"
done

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${BILLING_ACCOUNT_ID:?BILLING_ACCOUNT_ID is required}"
: "${ADMIN_CIDR:?ADMIN_CIDR is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
: "${MAVEN_IMAGE:?MAVEN_IMAGE is required}"
: "${GCLOUD_IMAGE:?GCLOUD_IMAGE is required}"

if [[ "$ADMIN_CIDR" == "0.0.0.0/0" || ! "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
  printf 'ADMIN_CIDR must be a single public IPv4 /32, not %s\n' "$ADMIN_CIDR" >&2
  exit 1
fi

required_tools=(git terraform docker jq make java dotnet python gcloud kubectl curl gke-gcloud-auth-plugin)
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required tool: %s\n' "$tool" >&2
    exit 1
  }
done

docker info >/dev/null
docker compose version >/dev/null
kubectl kustomize --help >/dev/null
python -c 'import matplotlib' >/dev/null 2>&1 || {
  printf 'Missing required Python package: matplotlib\n' >&2
  exit 1
}

active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" auth list \
  --filter='status:ACTIVE' --format='value(account)')"
configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
billing_enabled="$(gcloud --configuration="$GCLOUD_CONFIGURATION" billing projects describe \
  "$PROJECT_ID" --format='value(billingEnabled)')"

[[ "$active_account" == "satish.cse7@gmail.com" ]] || {
  printf 'Unexpected active account: %s\n' "$active_account" >&2
  exit 1
}
[[ "$configured_project" == "$PROJECT_ID" ]] || {
  printf 'Unexpected configured project: %s\n' "$configured_project" >&2
  exit 1
}
[[ "${billing_enabled,,}" == "true" ]] || {
  printf 'Billing is not enabled for %s\n' "$PROJECT_ID" >&2
  exit 1
}

dotnet --list-sdks | grep -q '^8\.'
docker run --rm "$MAVEN_IMAGE" mvn --version >/dev/null
docker run --rm "$GCLOUD_IMAGE" bq version >/dev/null

printf 'Gate 0 preflight passed\n'
printf '  account: %s\n' "$active_account"
printf '  project: %s\n' "$configured_project"
printf '  billing: enabled\n'
printf '  admin CIDR: %s\n' "$ADMIN_CIDR"

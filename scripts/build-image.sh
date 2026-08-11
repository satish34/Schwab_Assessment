#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage: %s APP_NAME [FULL_GIT_SHA]\n' "$0" >&2
  exit 2
fi

image_name="$1"
case "$image_name" in
  app-a)
    build_config="cloudbuild-app-a.yaml"
    dockerfile="apps/app-a-java/Dockerfile"
    ;;
  app-b)
    build_config="cloudbuild-app-b.yaml"
    dockerfile="apps/app-b-dotnet/Dockerfile"
    ;;
  *)
    printf 'APP_NAME must be app-a or app-b.\n' >&2
    exit 2
    ;;
esac

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

expected_project="schwab-assessment-gke"
expected_account="satish.cse7@gmail.com"
build_region="us-central1"

for command_name in gcloud git jq terraform; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

[[ "$PROJECT_ID" == "$expected_project" ]] || {
  printf 'Expected project %s, received %s.\n' "$expected_project" "$PROJECT_ID" >&2
  exit 1
}

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

head_sha="$(git rev-parse --verify HEAD^{commit})"
git_sha="${2:-$head_sha}"
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'The image version must be one full lowercase 40-character Git SHA.\n' >&2
  exit 1
}
[[ "$git_sha" == "$head_sha" ]] || {
  printf 'The requested image version must match the current HEAD commit.\n' >&2
  exit 1
}

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  printf 'The worktree must be clean so the image tag exactly identifies its source.\n' >&2
  exit 1
fi

repository="$(terraform -chdir=infra/10-global output -raw artifact_registry_repository)"
build_service_account="$(terraform -chdir=infra/10-global output -raw build_service_account_email)"
build_source_bucket="$(terraform -chdir=infra/10-global output -raw build_source_bucket)"
expected_repository="us-central1-docker.pkg.dev/$PROJECT_ID/risk"
expected_build_service_account="risk-cloud-build@$PROJECT_ID.iam.gserviceaccount.com"
expected_build_source_bucket="${PROJECT_ID}_cloudbuild"

[[ "$repository" == "$expected_repository" ]] || {
  printf 'Terraform returned unexpected Artifact Registry repository %s.\n' "$repository" >&2
  exit 1
}
[[ "$build_service_account" == "$expected_build_service_account" ]] || {
  printf 'Terraform returned unexpected build service account %s.\n' \
    "$build_service_account" >&2
  exit 1
}
[[ "$build_source_bucket" == "$expected_build_source_bucket" ]] || {
  printf 'Terraform returned unexpected build source bucket %s.\n' \
    "$build_source_bucket" >&2
  exit 1
}

repository_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    artifacts repositories describe risk \
    --location="$build_region" \
    --format=json
)"
jq -e \
  --arg name "projects/$PROJECT_ID/locations/$build_region/repositories/risk" \
  --arg uri "$repository" \
  '
    (.name == $name)
    and (.registryUri == $uri)
    and (.format == "DOCKER")
    and (.dockerConfig.immutableTags == true)
  ' <<<"$repository_json" >/dev/null || {
  printf 'Artifact Registry is not the expected immutable Docker repository.\n' >&2
  exit 1
}

live_build_service_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    iam service-accounts describe "$build_service_account" \
    --format='value(email)'
)"
[[ "$live_build_service_account" == "$build_service_account" ]] || {
  printf 'The dedicated Cloud Build service account is missing.\n' >&2
  exit 1
}

upload_files="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    meta list-files-for-upload . \
    | tr '\134' '/'
)"
for required_file in "$build_config" "$dockerfile"; do
  grep -Fx -- "$required_file" <<<"$upload_files" >/dev/null || {
    printf 'Cloud Build source would omit required file %s.\n' "$required_file" >&2
    exit 1
  }
done
sensitive_files="$(
  grep -E '(^|/)(\.env($|\.)|[^/]*\.tfstate($|\.)|service-account[^/]*\.json$|grafana-key[^/]*\.json$|\.git/)' \
    <<<"$upload_files" \
    | grep -Ev '(^|/)\.env\.example$' \
    || true
)"
if [[ -n "$sensitive_files" ]]; then
  printf 'Cloud Build source would include a credential, state, or Git-internal file.\n' >&2
  exit 1
fi

inventory="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    artifacts docker images list "$repository/$image_name" \
    --include-tags \
    --format=json
)"
if jq -e --arg sha "$git_sha" \
  'any(.[]; any((.tags // [])[]; . == $sha))' \
  <<<"$inventory" >/dev/null; then
  printf 'Immutable tag for %s already exists; verifying it without rebuilding.\n' \
    "$image_name"
  bash scripts/verify-image.sh "$image_name" "$git_sha"
  exit 0
fi

service_account_resource="projects/$PROJECT_ID/serviceAccounts/$build_service_account"
gcloud --configuration="$GCLOUD_CONFIGURATION" \
  --account="$expected_account" \
  --project="$PROJECT_ID" \
  builds submit . \
  --config="$build_config" \
  --gcs-source-staging-dir="gs://$build_source_bucket/source" \
  --ignore-file=.gcloudignore \
  --region="$build_region" \
  --service-account="$service_account_resource" \
  --substitutions="_GIT_SHA=$git_sha,_REPOSITORY=$repository" \
  --timeout=30m \
  --quiet

bash scripts/verify-image.sh "$image_name" "$git_sha"

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [FULL_GIT_SHA]\n' "$0" >&2
  exit 2
fi

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

expected_project="schwab-assessment-gke"
expected_account="satish.cse7@gmail.com"
repository_location="us-central1"

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

git_sha="${1:-$(git rev-parse --verify HEAD^{commit})}"
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'Image verification requires one full lowercase 40-character Git SHA.\n' >&2
  exit 1
}
git cat-file -e "$git_sha^{commit}" 2>/dev/null || {
  printf 'Git SHA %s is not a commit in this repository.\n' "$git_sha" >&2
  exit 1
}

repository="$(terraform -chdir=infra/10-global output -raw artifact_registry_repository)"
expected_repository="us-central1-docker.pkg.dev/$PROJECT_ID/risk"
[[ "$repository" == "$expected_repository" ]] || {
  printf 'Terraform returned unexpected Artifact Registry repository %s.\n' "$repository" >&2
  exit 1
}

repository_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" \
    --account="$expected_account" \
    --project="$PROJECT_ID" \
    artifacts repositories describe risk \
    --location="$repository_location" \
    --format=json
)"
jq -e \
  --arg name "projects/$PROJECT_ID/locations/$repository_location/repositories/risk" \
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

verify_image() {
  local image_name="$1"
  local image_path="$repository/$image_name"
  local inventory
  local digest
  local description

  inventory="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" \
      --project="$PROJECT_ID" \
      artifacts docker images list "$image_path" \
      --include-tags \
      --format=json
  )"

  digest="$(
    jq -er --arg sha "$git_sha" --arg image "$image_path" '
      [.[]
        | select(.package == $image)
        | select(any((.tags // [])[]; . == $sha))
        | .version] as $matches
      | if ($matches | length) == 1
        and ($matches[0] | test("^sha256:[0-9a-f]{64}$"))
        then $matches[0]
        else error("immutable Git-SHA tag did not resolve to exactly one digest")
        end
    ' <<<"$inventory"
  )" || {
    printf 'Image %s:%s does not resolve to exactly one digest.\n' \
      "$image_path" "$git_sha" >&2
    exit 1
  }

  jq -e \
    '[.[] | (.tags // [])[] | select(. == "latest")] | length == 0' \
    <<<"$inventory" >/dev/null || {
    printf 'Forbidden latest tag found on %s.\n' "$image_path" >&2
    exit 1
  }

  description="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" \
      --project="$PROJECT_ID" \
      artifacts docker images describe "$image_path:$git_sha" \
      --format=json
  )"
  jq -e \
    --arg digest "$digest" \
    --arg qualified "$image_path@$digest" \
    '
      (.image_summary.digest == $digest)
      and (.image_summary.fully_qualified_digest == $qualified)
    ' <<<"$description" >/dev/null || {
    printf 'Tag and digest metadata disagree for %s:%s.\n' \
      "$image_path" "$git_sha" >&2
    exit 1
  }

  printf '%s' "$digest"
}

app_a_digest="$(verify_image app-a)"
app_b_digest="$(verify_image app-b)"
[[ "$app_a_digest" != "$app_b_digest" ]] || {
  printf 'App A and App B unexpectedly resolved to the same digest.\n' >&2
  exit 1
}

printf '%s/app-a:%s -> %s\n' "$repository" "$git_sha" "$app_a_digest"
printf '%s/app-b:%s -> %s\n' "$repository" "$git_sha" "$app_b_digest"
printf 'Verified immutable full-SHA image tags for both applications.\n'

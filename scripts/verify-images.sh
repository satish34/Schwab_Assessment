#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  exit 2
fi

app_a_sha="$1"
app_b_sha="$2"
[[ "$app_a_sha" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$app_b_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'Image verification requires full lowercase 40-character Git SHAs.\n' >&2
  exit 1
}

app_a_digest="$(
  VERIFY_IMAGE_FORMAT=digest \
    bash scripts/verify-image.sh app-a "$app_a_sha"
)"
app_b_digest="$(
  VERIFY_IMAGE_FORMAT=digest \
    bash scripts/verify-image.sh app-b "$app_b_sha"
)"

[[ "$app_a_digest" != "$app_b_digest" ]] || {
  printf 'App A and App B unexpectedly resolved to the same digest.\n' >&2
  exit 1
}

repository="us-central1-docker.pkg.dev/$PROJECT_ID/risk"
printf '%s/app-a:%s -> %s\n' "$repository" "$app_a_sha" "$app_a_digest"
printf '%s/app-b:%s -> %s\n' "$repository" "$app_b_sha" "$app_b_digest"
printf 'Verified immutable full-SHA image pair (App A %s, App B %s).\n' \
  "$app_a_sha" "$app_b_sha"

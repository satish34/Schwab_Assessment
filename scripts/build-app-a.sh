#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [FULL_GIT_SHA]\n' "$0" >&2
  exit 2
fi

exec bash "$repo_root/scripts/build-image.sh" app-a "$@"

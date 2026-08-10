#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
image="ghcr.io/gitleaks/gitleaks:v8.24.2"
scan_timeout="${SECRET_SCAN_TIMEOUT:-10m}"

fail() {
  printf 'secret-scan: %s\n' "$*" >&2
  exit 1
}

for command_name in docker git tar timeout; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done
docker info >/dev/null 2>&1 || fail "Docker Desktop is not running"
[[ -z "${GITLEAKS_CONFIG:-}" && -z "${GITLEAKS_CONFIG_TOML:-}" ]] \
  || fail "Gitleaks configuration overrides must be unset"

native_path() {
  case "$(uname -s)" in
    MINGW*|MSYS*) cygpath -w "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

gitleaks() {
  local source="$1"
  local destination="$2"
  shift 2
  MSYS_NO_PATHCONV=1 timeout --foreground --signal=INT --kill-after=10s \
    "$scan_timeout" docker run --rm --network=none \
      --volume "$(native_path "$source"):$destination:ro" \
      --env GIT_CONFIG_COUNT=1 \
      --env GIT_CONFIG_KEY_0=safe.directory \
      --env GIT_CONFIG_VALUE_0="$destination" \
      "$image" "$@"
}

# Prove the pinned detector is active before trusting a clean result. The
# complete canary exists only in the pipe and is always redacted.
set +e
printf 'aws_access_key_id=%s%s\n' 'AKIA' 'A1B2C3D4E5F6G7H8' \
  | MSYS_NO_PATHCONV=1 timeout --foreground --signal=INT --kill-after=10s 2m \
      docker run --rm --network=none --interactive "$image" \
        stdin --no-banner --redact >/dev/null 2>&1
canary_code=$?
set -e
[[ "$canary_code" == "1" ]] \
  || fail "the pinned detector did not reject its runtime canary"

gitleaks "$repo_root" /repo git --no-banner --redact --verbose /repo

# Stream exactly the committable worktree. Tar keeps every file's bytes intact,
# while ignored runtime files, Terraform state, local credentials, and private
# interview notes never enter the detector.
git -C "$repo_root" ls-files --cached --others --exclude-standard -z \
  | while IFS= read -r -d '' path; do
      if [[ -f "$path" || -L "$path" ]]; then
        printf '%s\0' "$path"
      fi
    done \
  | tar --null --files-from=- --create --file=- \
  | MSYS_NO_PATHCONV=1 timeout --foreground --signal=INT --kill-after=10s \
      "$scan_timeout" docker run --rm --network=none --interactive "$image" \
        stdin --no-banner --redact --verbose
printf 'Secret scan passed for full Git history and the current worktree.\n'

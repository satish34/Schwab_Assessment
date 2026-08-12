#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

phase="${1:-}"
shift || true
evidence_dir="$repo_root/evidence"

fail() {
  printf 'capture-observability-evidence: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s manifest FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  printf '       %s cloud FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  printf '       %s platform\n' "$0" >&2
  printf '       %s grafana {start|verify|cleanup} FULL_GIT_SHA\n' "$0" >&2
  exit 2
}

require_sha_pair() {
  [[ $# -eq 2 ]] || usage
  [[ "$1" =~ ^[0-9a-f]{40}$ && "$2" =~ ^[0-9a-f]{40}$ ]] \
    || fail "both versions must be full lowercase 40-character Git SHAs"
  git cat-file -e "$1^{commit}" 2>/dev/null || fail "$1 is not a local commit"
  git cat-file -e "$2^{commit}" 2>/dev/null || fail "$2 is not a local commit"
}

require_release_sha() {
  local sha="$1"
  local head_sha
  head_sha="$(git rev-parse --verify HEAD^{commit})"
  [[ "$sha" == "$head_sha" ]] \
    || fail "observability evidence must target the current checked-out release commit"
}

for command_name in date git grep mktemp sed tail; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required"
done

mkdir -p "$repo_root/.tmp" "$evidence_dir"
git check-ignore --quiet -- "$evidence_dir" \
  || fail "the local evidence directory must remain ignored"

capture_atomic() {
  local target="$1"
  shift
  local candidate
  local exit_code
  local scan_status
  candidate="$(mktemp "$repo_root/.tmp/observability-evidence.XXXXXX")"
  git check-ignore --quiet -- "$candidate" \
    || fail "the evidence candidate path must remain ignored"
  cleanup_candidate() {
    rm -f -- "$candidate"
  }
  trap cleanup_candidate RETURN
  set +e
  "$@" >"$candidate" 2>&1
  exit_code=$?
  set -e
  # Scan before displaying or retaining any verifier output. A failed verifier
  # must not turn this wrapper into a credential-disclosure path.
  set +e
  grep -Eiq \
    'authorization:|bearer[[:space:]]+[a-z0-9._-]{20,}|ya29\.|"(access_token|refresh_token|private_key|private_key_id|client_secret)"' \
    "$candidate"
  scan_status=$?
  set -e
  if ((scan_status == 0)); then
    rm -f -- "$candidate"
    trap - RETURN
    fail "live gate output contained token-like material; output was deleted without replay"
  fi
  if ((scan_status != 1)); then
    rm -f -- "$candidate"
    trap - RETURN
    fail "could not safely scan live gate output; output was deleted without replay"
  fi
  if ((exit_code != 0)); then
    printf 'Live gate failed with exit code %s; showing at most the final 8 KiB / 80 lines:\n' \
      "$exit_code" >&2
    LC_ALL=C tail -c 8192 -- "$candidate" | tail -n 80 >&2
    rm -f -- "$candidate"
    trap - RETURN
    fail "live gate failed; retained evidence was not replaced"
  fi
  if [[ ! -s "$candidate" ]]; then
    rm -f -- "$candidate"
    trap - RETURN
    fail "live gate emitted no evidence"
  fi
  mv -f -- "$candidate" "$evidence_dir/$target"
  trap - RETURN
  printf 'Captured local non-secret %s.\n' "$target"
}

manifest_release_sha() {
  local manifest_sha
  local status
  status="$(git status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] \
    || fail "observability evidence capture requires a clean worktree"
  [[ -s "$evidence_dir/18-release-manifest.txt" ]] \
    || fail "capture 18-release-manifest.txt before observability evidence"
  manifest_sha="$(sed -n 's/^release_source_sha=//p' \
    "$evidence_dir/18-release-manifest.txt")"
  [[ "$manifest_sha" =~ ^[0-9a-f]{40}$ ]] \
    || fail "the retained release manifest has an invalid source SHA"
  git merge-base --is-ancestor "$manifest_sha" HEAD \
    || fail "the retained release SHA is not an ancestor of the current documentation HEAD"
  printf '%s\n' "$manifest_sha"
}

require_manifest_sha() {
  local sha="$1"
  local manifest_sha
  manifest_sha="$(manifest_release_sha)"
  [[ "$manifest_sha" == "$sha" ]] \
    || fail "the retained release manifest does not match the requested release SHA"
}

write_manifest() {
  local app_a_sha="$1"
  local app_b_sha="$2"
  local head_sha status
  local candidate
  head_sha="$(git rev-parse --verify HEAD^{commit})"
  status="$(git status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] || fail "the release manifest requires a clean worktree"
  [[ "$app_a_sha" == "$app_b_sha" ]] \
    || fail "the final paired assessment release must use one exact source SHA"
  git merge-base --is-ancestor "$app_a_sha" "$head_sha" \
    || fail "the deployed release SHA must be the clean documentation HEAD or its ancestor"
  candidate="$(mktemp "$repo_root/.tmp/release-manifest.XXXXXX")"
  git check-ignore --quiet -- "$candidate" || fail "manifest candidate must remain ignored"
  {
    printf 'captured_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'repository=https://github.com/satish34/Schwab_Assessment\n'
    printf 'branch=main\n'
    printf 'release_source_sha=%s\n' "$app_a_sha"
    printf 'documentation_head_sha=%s\n' "$head_sha"
    printf 'app_a_sha=%s\n' "$app_a_sha"
    printf 'app_b_sha=%s\n' "$app_b_sha"
    printf 'public_endpoint=https://satish.store\n'
    printf 'worktree=clean\n'
  } >"$candidate"
  mv -f -- "$candidate" "$evidence_dir/18-release-manifest.txt"
  printf '%s\n' 'Captured local non-secret 18-release-manifest.txt.'
}

case "$phase" in
  manifest)
    require_sha_pair "$@"
    write_manifest "$1" "$2"
    ;;
  cloud)
    require_sha_pair "$@"
    require_release_sha "$1"
    require_release_sha "$2"
    require_manifest_sha "$1"
    capture_atomic 19-cloud-observability.txt \
      bash "$repo_root/scripts/verify-cloud-observability.sh" "$1" "$2"
    ;;
  platform)
    [[ $# -eq 0 ]] || usage
    manifest_release_sha >/dev/null
    capture_atomic 20-platform-observability.txt \
      bash "$repo_root/scripts/verify-platform-observability.sh"
    ;;
  grafana)
    [[ $# -eq 2 ]] || usage
    [[ "$2" =~ ^[0-9a-f]{40}$ ]] \
      || fail "the Grafana image version must be a full lowercase 40-character Git SHA"
    case "$1" in
      start)
        git cat-file -e "$2^{commit}" 2>/dev/null || fail "$2 is not a local commit"
        require_manifest_sha "$2"
        # Start is deliberately not captured: it creates the short-lived Job and
        # leaves the loopback tunnel running for browser inspection.
        bash "$repo_root/scripts/gke-grafana-evidence.sh" start "$2"
        printf 'Capture evidence/08-grafana.png through the printed loopback URL, then run the grafana verify and cleanup phases with GRAFANA_IMAGE_TAG=%s.\n' \
          "$2"
        ;;
      verify)
        git cat-file -e "$2^{commit}" 2>/dev/null || fail "$2 is not a local commit"
        require_manifest_sha "$2"
        capture_atomic 21-gke-grafana.txt \
          bash "$repo_root/scripts/gke-grafana-evidence.sh" verify "$2"
        ;;
      cleanup)
        bash "$repo_root/scripts/gke-grafana-evidence.sh" cleanup "$2"
        ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac

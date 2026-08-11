#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
runtime_dir="$repo_root/.tmp"
gate_kubeconfig="${VERIFIER_KUBECONFIG:-$runtime_dir/kubeconfig-verifier-gate-${BASHPID:-$$}}"

cleanup() {
  local exit_code=$?
  case "$gate_kubeconfig" in
    "$runtime_dir"/kubeconfig-verifier-gate-*) rm -f -- "$gate_kubeconfig" ;;
  esac
  trap - EXIT INT TERM
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'verify-deployment-gates: %s\n' "$*" >&2
  exit 1
}

gate_mode=full
if [[ "${1:-}" == "--pre-edge" ]]; then
  gate_mode=pre-edge
  shift
fi
if [[ $# -ne 2 ]]; then
  printf 'Usage: %s [--pre-edge] FULL_APP_A_GIT_SHA FULL_APP_B_GIT_SHA\n' "$0" >&2
  exit 2
fi
app_a_sha="$1"
app_b_sha="$2"
[[ "$app_a_sha" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$app_b_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "both image versions must be full lowercase 40-character Git SHAs"
case "$gate_kubeconfig" in
  "$runtime_dir"/kubeconfig-verifier-gate-*) ;;
  *) fail "VERIFIER_KUBECONFIG must be an isolated gate path under the ignored runtime directory" ;;
esac
mkdir -p "$runtime_dir"
git check-ignore --quiet -- "$gate_kubeconfig" \
  || fail "the isolated gate kubeconfig path is not ignored by Git"
export VERIFIER_KUBECONFIG="$gate_kubeconfig"

printf '[gate 1/5] immutable image pair\n'
bash scripts/verify-images.sh "$app_a_sha" "$app_b_sha"
printf '[gate 2/5] exact two-region workload pair and signed/unsigned service-auth paths\n'
bash scripts/verify-workloads.sh "$app_a_sha" "$app_b_sha"
printf '[gate 3/5] separate-team identity and namespace isolation\n'
bash scripts/verify-team-isolation.sh
printf '[gate 4/5] six exact App A zonal NEGs\n'
bash scripts/wait-negs.sh "$app_a_sha" "$app_b_sha"
if [[ "$gate_mode" == "pre-edge" ]]; then
  printf '[gate 5/5] HTTPS edge intentionally deferred for one-time NEG ownership migration\n'
  printf 'Pre-edge deployment gates: PASS for App A %s / App B %s in both regions.\n' \
    "$app_a_sha" "$app_b_sha"
  printf 'Ops must now apply 30-lb, then run this script again without --pre-edge.\n'
  exit 0
fi
printf '[gate 5/5] HTTPS edge, backend health, and public response\n'
bash scripts/verify-lb.sh "$app_a_sha" "$app_b_sha"
printf 'Deployment gates: PASS for App A %s / App B %s in both regions.\n' \
  "$app_a_sha" "$app_b_sha"

#!/usr/bin/env bash
set -euo pipefail

# Classifies only inventories that are safe for the coordinated platform apply.
# Arguments are aggregate counts across exactly two clusters.
classify_platform_inventory() {
  local team_namespaces="${1:-}" observability_namespaces="${2:-}"
  local app_a_services="${3:-}" app_b_services="${4:-}"
  case "$team_namespaces|$observability_namespaces|$app_a_services|$app_b_services" in
    '0|0|0|0') printf '%s\n' bootstrap ;;
    '4|0|2|2') printf '%s\n' expansion ;;
    '4|2|2|2') printf '%s\n' steady ;;
    *)
      printf 'unsafe platform inventory: team=%s observability=%s app-a-services=%s app-b-services=%s\n' \
        "$team_namespaces" "$observability_namespaces" "$app_a_services" "$app_b_services" >&2
      return 1
      ;;
  esac
}

run_contract_tests() {
  local actual rejected fixture
  for fixture in \
    '0|0|0|0|bootstrap' \
    '4|0|2|2|expansion' \
    '4|2|2|2|steady'; do
    IFS='|' read -r team obs app_a app_b expected <<<"$fixture"
    actual="$(classify_platform_inventory "$team" "$obs" "$app_a" "$app_b")"
    [[ "$actual" == "$expected" ]] || return 1
  done
  for fixture in \
    '1|0|0|0' '2|0|0|0' '3|0|0|0' \
    '4|1|2|2' '4|0|1|2' '4|0|2|1' \
    '4|2|1|2' '4|2|2|1' '0|2|0|0' \
    '0|0|2|2' '4|0|0|0'; do
    IFS='|' read -r team obs app_a app_b <<<"$fixture"
    rejected=0
    classify_platform_inventory "$team" "$obs" "$app_a" "$app_b" >/dev/null 2>&1 \
      || rejected=1
    ((rejected == 1)) || {
      printf 'unsafe fixture was accepted: %s\n' "$fixture" >&2
      return 1
    }
  done
  printf '%s\n' \
    'Platform cutover contract: PASS (bootstrap, symmetric expansion, steady state, and partial-state rejection).'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_contract_tests
fi

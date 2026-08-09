#!/usr/bin/env bash
set -euo pipefail

mode="${1:-apply}"
expected_account="satish.cse7@gmail.com"

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

case "$mode" in
  check|apply) ;;
  *)
    printf 'Usage: %s check|apply\n' "$0" >&2
    exit 2
    ;;
esac

active_account="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null
)"
configured_project="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null
)"

[[ "$active_account" == "$expected_account" ]] || {
  printf 'Expected gcloud account %s, found %s.\n' \
    "$expected_account" "${active_account:-<none>}" >&2
  exit 1
}
[[ "$configured_project" == "$PROJECT_ID" ]] || {
  printf 'Expected gcloud project %s, found %s.\n' \
    "$PROJECT_ID" "${configured_project:-<none>}" >&2
  exit 1
}

networks_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute networks list \
    --project="$PROJECT_ID" \
    --filter='name=default' \
    --format=json
)"
network_count="$(jq 'length' <<<"$networks_json")"

if [[ "$network_count" == "0" ]]; then
  printf 'Verified the default VPC is already absent.\n'
  exit 0
fi

[[ "$network_count" == "1" ]] || {
  printf 'Expected at most one network named default, found %s.\n' \
    "$network_count" >&2
  exit 1
}

jq -e \
  --arg project "$PROJECT_ID" \
  '
    .[0].name == "default"
    and .[0].description == "Default network for the project"
    and .[0].autoCreateSubnetworks == true
    and .[0].selfLink == (
      "https://www.googleapis.com/compute/v1/projects/"
      + $project
      + "/global/networks/default"
    )
  ' <<<"$networks_json" >/dev/null || {
    printf 'Refusing to remove a network that is not the untouched auto VPC.\n' >&2
    exit 1
  }

instances_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute instances list \
    --project="$PROJECT_ID" \
    --format=json
)"
jq -e \
  '[
    .[]
    | select(any(.networkInterfaces[]?; .network | endswith("/default")))
  ]
  | length == 0' <<<"$instances_json" >/dev/null || {
    printf 'Refusing to remove the default VPC while a VM uses it.\n' >&2
    exit 1
  }

firewalls_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute firewall-rules list \
    --project="$PROJECT_ID" \
    --filter="network~'/default$'" \
    --format=json
)"
jq -e '
  all(.[].name;
    . == "default-allow-icmp"
    or . == "default-allow-internal"
    or . == "default-allow-rdp"
    or . == "default-allow-ssh"
  )
' <<<"$firewalls_json" >/dev/null || {
  printf 'Refusing to remove a default VPC with nonstandard firewall rules.\n' >&2
  exit 1
}

mapfile -t firewall_names < <(jq -r '.[].name' <<<"$firewalls_json")
for index in "${!firewall_names[@]}"; do
  firewall_names[$index]="${firewall_names[$index]%$'\r'}"
  [[ "${firewall_names[$index]}" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || {
    printf 'Refusing an invalid firewall name returned by the API.\n' >&2
    exit 1
  }
done

if [[ "$mode" == "check" ]]; then
  printf 'Verified the unused auto-created default VPC is safe to remove.\n'
  exit 0
fi

[[ "${ALLOW_DEFAULT_NETWORK_DELETE:-0}" == "1" ]] || {
  printf 'Set ALLOW_DEFAULT_NETWORK_DELETE=1 only from the Terraform cleanup resource.\n' >&2
  exit 1
}

if ((${#firewall_names[@]} > 0)); then
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute firewall-rules delete \
    "${firewall_names[@]}" \
    --project="$PROJECT_ID" \
    --quiet
fi

gcloud --configuration="$GCLOUD_CONFIGURATION" compute networks delete default \
  --project="$PROJECT_ID" \
  --quiet

remaining="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute networks list \
    --project="$PROJECT_ID" \
    --filter='name=default' \
    --format='value(name)'
)"
[[ -z "$remaining" ]] || {
  printf 'The default VPC still exists after the delete operation.\n' >&2
  exit 1
}

printf 'Removed the verified unused auto-created default VPC.\n'

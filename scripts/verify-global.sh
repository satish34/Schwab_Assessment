#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

expected_account="satish.cse7@gmail.com"
active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
[[ "$active_account" == "$expected_account" ]] || {
  printf 'Expected gcloud account %s, found %s.\n' "$expected_account" "${active_account:-<none>}" >&2
  exit 1
}

if [[ -z "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]; then
  GOOGLE_OAUTH_ACCESS_TOKEN="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" auth print-access-token
  )"
  export GOOGLE_OAUTH_ACCESS_TOKEN
  trap 'unset GOOGLE_OAUTH_ACCESS_TOKEN' EXIT
fi

project_number="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" projects describe "$PROJECT_ID" \
    --format='value(projectNumber)'
)"
[[ "$project_number" =~ ^[0-9]+$ ]] || {
  printf 'Could not resolve the numeric project ID.\n' >&2
  exit 1
}

node_usc1="risk-gke-usc1-nodes@$PROJECT_ID.iam.gserviceaccount.com"
node_use4="risk-gke-use4-nodes@$PROJECT_ID.iam.gserviceaccount.com"
build_sa="risk-cloud-build@$PROJECT_ID.iam.gserviceaccount.com"
grafana_sa="grafana-reader@$PROJECT_ID.iam.gserviceaccount.com"

outputs_json="$(terraform -chdir=infra/10-global output -json)"
jq -e \
  --arg project "$PROJECT_ID" \
  --arg node_usc1 "$node_usc1" \
  --arg node_use4 "$node_use4" \
  --arg build "$build_sa" \
  --arg grafana "$grafana_sa" \
  '
    (.project_id.value == $project)
    and (.project_number.value | test("^[0-9]+$"))
    and (.network_name.value == "risk-vpc")
    and (.subnetwork_names.value == {
      "us-central1": "risk-usc1",
      "us-east4": "risk-use4"
    })
    and (.secondary_ranges.value == {
      "us-central1": {"pods": "risk-usc1-pods", "services": "risk-usc1-services"},
      "us-east4": {"pods": "risk-use4-pods", "services": "risk-use4-services"}
    })
    and (.artifact_registry_repository.value == ("us-central1-docker.pkg.dev/" + $project + "/risk"))
    and (.global_address_name.value == "risk-global-ip")
    and (.global_ipv4_address.value | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
    and (.health_firewall_name.value == "risk-allow-gfe-to-app-a")
    and (.bigquery_dataset_id.value == "risk_logs")
    and (.log_sink_name.value == "risk-app-stdout-to-bigquery")
    and (.node_service_account_emails.value == {
      "us-central1": $node_usc1,
      "us-east4": $node_use4
    })
    and (.build_service_account_email.value == $build)
    and (.build_source_bucket.value == ($project + "_cloudbuild"))
    and (.grafana_reader_email.value == $grafana)
  ' <<<"$outputs_json" >/dev/null || {
    printf 'The 10-global Terraform outputs do not match the frozen contract.\n' >&2
    exit 1
  }

if [[ -z "${DOMAIN_NAME:-}" ]]; then
  jq -e '
    (.dns_name_servers.value == [])
    and (.domain_name.value == "")
    and (.certificate_map_id.value == "")
  ' <<<"$outputs_json" >/dev/null || {
    printf 'TLS outputs exist even though DOMAIN_NAME is empty.\n' >&2
    exit 1
  }
else
  normalized_domain="$(
    printf '%s' "$DOMAIN_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[.]$//'
  )"
  jq -e --arg domain "$normalized_domain" '
    (.dns_name_servers.value | length) > 0
    and (.domain_name.value == $domain)
    and (.certificate_map_id.value | endswith("/certificateMaps/risk-cert-map"))
  ' <<<"$outputs_json" >/dev/null || {
    printf 'TLS outputs are incomplete for the supplied DOMAIN_NAME.\n' >&2
    exit 1
  }
fi

networks_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute networks list \
    --project="$PROJECT_ID" \
    --format=json
)"
jq -e '[.[].name] | sort == ["risk-vpc"]' <<<"$networks_json" >/dev/null || {
  printf 'The live VPC inventory is not exactly risk-vpc.\n' >&2
  exit 1
}

verify_subnet() {
  local name="$1"
  local region="$2"
  local primary_cidr="$3"
  local pod_name="$4"
  local pod_cidr="$5"
  local service_name="$6"
  local service_cidr="$7"
  local subnet_json

  subnet_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" compute networks subnets describe "$name" \
      --project="$PROJECT_ID" \
      --region="$region" \
      --format=json
  )"
  jq -e \
    --arg primary "$primary_cidr" \
    --arg pod_name "$pod_name" \
    --arg pod_cidr "$pod_cidr" \
    --arg service_name "$service_name" \
    --arg service_cidr "$service_cidr" \
    '
      (.ipCidrRange == $primary)
      and (.privateIpGoogleAccess == true)
      and (
        [.secondaryIpRanges[] | {key: .rangeName, value: .ipCidrRange}]
        | from_entries
        == {($pod_name): $pod_cidr, ($service_name): $service_cidr}
      )
    ' <<<"$subnet_json" >/dev/null
}

verify_subnet risk-usc1 us-central1 10.10.0.0/20 \
  risk-usc1-pods 10.20.0.0/16 risk-usc1-services 10.30.0.0/20 || {
  printf 'The live us-central1 subnet does not match its frozen ranges or PGA setting.\n' >&2
  exit 1
}
verify_subnet risk-use4 us-east4 10.11.0.0/20 \
  risk-use4-pods 10.21.0.0/16 risk-use4-services 10.31.0.0/20 || {
  printf 'The live us-east4 subnet does not match its frozen ranges or PGA setting.\n' >&2
  exit 1
}

registry_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" artifacts repositories describe risk \
    --project="$PROJECT_ID" \
    --location=us-central1 \
    --format=json
)"
jq -e '
  (.format == "DOCKER")
  and (.dockerConfig.immutableTags == true)
' <<<"$registry_json" >/dev/null || {
  printf 'Artifact Registry is not an immutable Docker repository.\n' >&2
  exit 1
}

address_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute addresses describe risk-global-ip \
    --project="$PROJECT_ID" \
    --global \
    --format=json
)"
jq -e '
  (.addressType == "EXTERNAL")
  and ((.ipVersion // "IPV4") == "IPV4")
  and (.address | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
  and (.status == "RESERVED" or .status == "IN_USE")
' <<<"$address_json" >/dev/null || {
  printf 'The global external IPv4 address is not reserved or in use.\n' >&2
  exit 1
}

firewall_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" compute firewall-rules describe \
    risk-allow-gfe-to-app-a \
    --project="$PROJECT_ID" \
    --format=json
)"
jq -e \
  --arg node_usc1 "$node_usc1" \
  --arg node_use4 "$node_use4" \
  '
    (.direction == "INGRESS")
    and ([.sourceRanges[]] | sort == ["130.211.0.0/22", "35.191.0.0/16"])
    and ([.targetServiceAccounts[]] | sort == ([$node_usc1, $node_use4] | sort))
    and ([.allowed[] | select(.IPProtocol == "tcp") | .ports[]] == ["8080"])
  ' <<<"$firewall_json" >/dev/null || {
    printf 'The health-check firewall does not match its sources, targets, or port.\n' >&2
    exit 1
  }

project_policy="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" projects get-iam-policy "$PROJECT_ID" \
    --format=json
)"
default_sa="serviceAccount:${project_number}-compute@developer.gserviceaccount.com"
jq -e \
  --arg default_sa "$default_sa" \
  --arg node_usc1 "serviceAccount:$node_usc1" \
  --arg node_use4 "serviceAccount:$node_use4" \
  --arg build "serviceAccount:$build_sa" \
  --arg grafana "serviceAccount:$grafana_sa" \
  --arg grafana_metadata "projects/$PROJECT_ID/roles/grafanaProjectReader" \
  '
    def roles_for($member):
      [.bindings[] | select(any(.members[]?; . == $member)) | .role] | sort;
    ([.bindings[] | select(.role == "roles/editor") | .members[]? | select(. == $default_sa)] | length == 0)
    and (roles_for($node_usc1) == ["roles/container.defaultNodeServiceAccount"])
    and (roles_for($node_use4) == ["roles/container.defaultNodeServiceAccount"])
    and (roles_for($build) == ["roles/logging.logWriter"])
    and (roles_for($grafana) == ([$grafana_metadata, "roles/bigquery.jobUser", "roles/monitoring.viewer"] | sort))
  ' <<<"$project_policy" >/dev/null || {
    printf 'Default, node, or build project IAM does not match the least-privilege contract.\n' >&2
    exit 1
  }

registry_policy="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" artifacts repositories get-iam-policy risk \
    --project="$PROJECT_ID" \
    --location=us-central1 \
    --format=json
)"
jq -e \
  --arg node_usc1 "serviceAccount:$node_usc1" \
  --arg node_use4 "serviceAccount:$node_use4" \
  --arg build "serviceAccount:$build_sa" \
  '
    (
      [.bindings[] | select(.role == "roles/artifactregistry.reader") | .members[]?]
      | sort
      == ([$node_usc1, $node_use4] | sort)
    )
    and (
      [.bindings[] | select(.role == "roles/artifactregistry.writer") | .members[]?]
      == [$build]
    )
  ' <<<"$registry_policy" >/dev/null || {
    printf 'Artifact Registry reader/writer IAM does not match the node/build identities.\n' >&2
  exit 1
}

build_source_bucket="${PROJECT_ID}_cloudbuild"
build_source_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" storage buckets describe \
    "gs://$build_source_bucket" \
    --format=json
)"
jq -e \
  --arg bucket "$build_source_bucket" \
  '
    (.name == $bucket)
    and (.location == "US")
    and (.default_storage_class == "STANDARD")
    and (.uniform_bucket_level_access == true)
    and (.public_access_prevention == "enforced")
    and (.soft_delete_policy.retentionDurationSeconds == "0")
    and (.lifecycle_config.rule == [{
      "action": {"type": "Delete"},
      "condition": {"age": 7, "matchesPrefix": ["source/"]}
    }])
  ' <<<"$build_source_json" >/dev/null || {
    printf 'The Cloud Build source bucket is not private or does not match its contract.\n' >&2
    exit 1
  }

build_source_policy="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" storage buckets get-iam-policy \
    "gs://$build_source_bucket" \
    --format=json
)"
jq -e \
  --arg build "serviceAccount:$build_sa" \
  '
    ([
      .bindings[]
      | select(.role == "roles/storage.objectViewer")
      | .members[]?
      | select(. == $build)
    ] | length == 1)
    and ([
      .bindings[]
      | .members[]?
      | select(. == "allUsers" or . == "allAuthenticatedUsers")
    ] | length == 0)
  ' <<<"$build_source_policy" >/dev/null || {
    printf 'The Cloud Build identity cannot read the private source bucket.\n' >&2
    exit 1
  }

sink_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" logging sinks describe \
    risk-app-stdout-to-bigquery \
    --project="$PROJECT_ID" \
    --format=json
)"
sink_writer="$(jq -r '.writerIdentity // ""' <<<"$sink_json")"
jq -e \
  --arg destination "bigquery.googleapis.com/projects/$PROJECT_ID/datasets/risk_logs" \
  '
    (.destination == $destination)
    and (.bigqueryOptions.usePartitionedTables == true)
    and (.writerIdentity | startswith("serviceAccount:"))
  ' <<<"$sink_json" >/dev/null || {
    printf 'The application log sink destination, partitioning, or writer is invalid.\n' >&2
    exit 1
  }

dataset_json="$(
  printf 'header = "Authorization: Bearer %s"\n' "$GOOGLE_OAUTH_ACCESS_TOKEN" \
    | curl --silent --show-error --fail --config - \
        "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/datasets/risk_logs"
)"
jq -e \
  --arg writer "$sink_writer" \
  --arg grafana "serviceAccount:$grafana_sa" \
  '
    ([
      .access[]?
      | select(
          (.role == "WRITER" or .role == "roles/bigquery.dataEditor")
          and (
            .iamMember == $writer
            or ("serviceAccount:" + (.userByEmail // "")) == $writer
          )
        )
    ] | length == 1)
    and ([
      .access[]?
      | select(
          (.role == "READER" or .role == "roles/bigquery.dataViewer")
          and (
            .iamMember == $grafana
            or ("serviceAccount:" + (.userByEmail // "")) == $grafana
          )
        )
    ] | length == 1)
  ' <<<"$dataset_json" >/dev/null || {
    printf 'Dataset IAM does not match the sink-writer and Grafana-reader contract.\n' >&2
    exit 1
  }

jq -e --arg writer "$sink_writer" '
  [
    .bindings[]
    | select(.role | startswith("roles/bigquery."))
    | .members[]?
    | select(. == $writer)
  ]
  | length == 0
' <<<"$project_policy" >/dev/null || {
  printf 'The sink writer has an unintended project-level BigQuery role.\n' >&2
  exit 1
}

verify_no_user_keys() {
  local account="$1"
  local keys
  keys="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" iam service-accounts keys list \
      --iam-account="$account" \
      --project="$PROJECT_ID" \
      --filter='keyType=USER_MANAGED' \
      --format='value(name)'
  )"
  [[ -z "$keys" ]]
}

for account in "$node_usc1" "$node_use4" "$build_sa" "$grafana_sa"; do
  verify_no_user_keys "$account" || {
    printf 'User-managed key found on %s.\n' "$account" >&2
    exit 1
  }
done

printf 'Verified 10-global outputs, live resources, and scoped IAM.\n'

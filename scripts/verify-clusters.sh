#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
: "${ADMIN_CIDR:?ADMIN_CIDR is required}"

expected_account="satish.cse7@gmail.com"
active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
[[ "$active_account" == "$expected_account" ]] || {
  printf 'Expected gcloud account %s, found %s.\n' "$expected_account" "${active_account:-<none>}" >&2
  exit 1
}

configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
[[ "$configured_project" == "$PROJECT_ID" ]] || {
  printf 'Expected gcloud project %s, found %s.\n' "$PROJECT_ID" "${configured_project:-<none>}" >&2
  exit 1
}

if [[ ! "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
  printf 'ADMIN_CIDR must be one IPv4 address in exact /32 notation.\n' >&2
  exit 1
fi

admin_ip="${ADMIN_CIDR%/32}"
IFS='.' read -r -a admin_octets <<<"$admin_ip"
for octet in "${admin_octets[@]}"; do
  if [[ ( "$octet" != "0" && "$octet" == 0* ) ]] || ((10#$octet > 255)); then
    printf 'ADMIN_CIDR must be one canonical IPv4 address in exact /32 notation.\n' >&2
    exit 1
  fi
done
[[ "$admin_ip" != "0.0.0.0" ]] || {
  printf 'ADMIN_CIDR must not authorize 0.0.0.0/32.\n' >&2
  exit 1
}

node_usc1="risk-gke-usc1-nodes@$PROJECT_ID.iam.gserviceaccount.com"
node_use4="risk-gke-use4-nodes@$PROJECT_ID.iam.gserviceaccount.com"

outputs_json="$(terraform -chdir=infra/20-cluster output -json)"
jq -e \
  --arg project "$PROJECT_ID" \
  --arg node_usc1 "$node_usc1" \
  --arg node_use4 "$node_use4" \
  '
    def resource_name:
      if type == "string" then split("/")[-1] else "" end;

    (.cluster_names.value == {
      "us-central1": "gke-risk-usc1",
      "us-east4": "gke-risk-use4"
    })
    and (.cluster_locations.value == {
      "us-central1": "us-central1",
      "us-east4": "us-east4"
    })
    and (.node_service_account_emails.value == {
      "us-central1": $node_usc1,
      "us-east4": $node_use4
    })
    and ((.clusters.value | keys | sort) == ["us-central1", "us-east4"])
    and (.clusters.value["us-central1"] as $cluster
      | ($cluster.name == "gke-risk-usc1")
        and ($cluster.location == "us-central1")
        and ($cluster.project == $project)
        and (($cluster.network | resource_name) == "risk-vpc")
        and (($cluster.subnet | resource_name) == "risk-usc1")
        and ($cluster.node_service_account_email == $node_usc1))
    and (.clusters.value["us-east4"] as $cluster
      | ($cluster.name == "gke-risk-use4")
        and ($cluster.location == "us-east4")
        and ($cluster.project == $project)
        and (($cluster.network | resource_name) == "risk-vpc")
        and (($cluster.subnet | resource_name) == "risk-use4")
        and ($cluster.node_service_account_email == $node_use4))
  ' <<<"$outputs_json" >/dev/null || {
    printf 'The 20-cluster Terraform outputs do not match the frozen regional contract.\n' >&2
    exit 1
  }

# deletion_protection is Terraform lifecycle state, not a GKE API property.
state_json="$(terraform -chdir=infra/20-cluster show -json)"
jq -e '
  def all_resources:
    .resources[]?, (.child_modules[]? | all_resources);

  [.values.root_module
    | all_resources
    | select(.type == "google_container_cluster")
  ] as $clusters
  | ($clusters | length) == 2
    and ([$clusters[].values.location] | sort == ["us-central1", "us-east4"])
    and all($clusters[];
      (.values.enable_autopilot == true)
      and (.values.deletion_protection == false)
    )
' <<<"$state_json" >/dev/null || {
  printf 'Terraform state does not contain exactly two deletable Autopilot clusters.\n' >&2
  exit 1
}

inventory_json="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" container clusters list \
    --project="$PROJECT_ID" \
    --format=json
)"
jq -e '
  [.[]
    | {name, location: (.location // .zone // "")}
  ]
  | sort_by(.name)
  == [
    {"name": "gke-risk-usc1", "location": "us-central1"},
    {"name": "gke-risk-use4", "location": "us-east4"}
  ]
' <<<"$inventory_json" >/dev/null || {
  printf 'The live GKE inventory is not exactly the two frozen regional clusters.\n' >&2
  exit 1
}

verify_cluster() {
  local name="$1"
  local region="$2"
  local subnet="$3"
  local pod_range="$4"
  local service_range="$5"
  local master_cidr="$6"
  local node_service_account="$7"
  shift 7
  local expected_zones=("$@")
  local zones_json
  local cluster_json

  zones_json="$(printf '%s\n' "${expected_zones[@]}" | jq -R . | jq -s 'sort')"
  cluster_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" container clusters describe "$name" \
      --project="$PROJECT_ID" \
      --location="$region" \
      --format=json
  )"

  jq -e \
    --arg name "$name" \
    --arg region "$region" \
    --arg subnet "$subnet" \
    --arg pod_range "$pod_range" \
    --arg service_range "$service_range" \
    --arg master_cidr "$master_cidr" \
    --arg admin_cidr "$ADMIN_CIDR" \
    --arg node_service_account "$node_service_account" \
    --arg workload_pool "$PROJECT_ID.svc.id.goog" \
    --argjson zones "$zones_json" \
    '
      def resource_name:
        if type == "string" then split("/")[-1] else "" end;
      def object_has($key):
        type == "object" and has($key);
      def authorized_network_configs:
        [
          (if (.masterAuthorizedNetworksConfig | type) == "object"
            then .masterAuthorizedNetworksConfig else empty end),
          (if (.controlPlaneEndpointsConfig.ipEndpointsConfig.authorizedNetworksConfig | type) == "object"
            then .controlPlaneEndpointsConfig.ipEndpointsConfig.authorizedNetworksConfig else empty end)
        ];
      def private_node_flags:
        [
          (if (.privateClusterConfig | object_has("enablePrivateNodes"))
            then .privateClusterConfig.enablePrivateNodes else empty end),
          (if (.networkConfig | object_has("defaultEnablePrivateNodes"))
            then .networkConfig.defaultEnablePrivateNodes else empty end)
        ];
      def public_endpoint_flags:
        [
          (if (.privateClusterConfig | object_has("enablePrivateEndpoint"))
            then (.privateClusterConfig.enablePrivateEndpoint == false) else empty end),
          (if (.controlPlaneEndpointsConfig.ipEndpointsConfig | object_has("enablePublicEndpoint"))
            then .controlPlaneEndpointsConfig.ipEndpointsConfig.enablePublicEndpoint else empty end)
        ];
      def global_access_flags:
        [
          (if (.privateClusterConfig.masterGlobalAccessConfig | object_has("enabled"))
            then .privateClusterConfig.masterGlobalAccessConfig.enabled else empty end),
          (if (.controlPlaneEndpointsConfig.ipEndpointsConfig | object_has("globalAccess"))
            then .controlPlaneEndpointsConfig.ipEndpointsConfig.globalAccess else empty end)
        ];
      def public_endpoint:
        (.controlPlaneEndpointsConfig.ipEndpointsConfig.publicEndpoint
          // .privateClusterConfig.publicEndpoint
          // .endpoint
          // "");
      def node_service_account:
        (.autoscaling.autoprovisioningNodePoolDefaults.serviceAccount
          // .clusterAutoscaling.autoProvisioningDefaults.serviceAccount
          // "");

      authorized_network_configs as $authorized_networks
      | private_node_flags as $private_nodes
      | public_endpoint_flags as $public_endpoints
      | global_access_flags as $global_access
      | (.networkConfig.datapathProvider // .datapathProvider // "") as $datapath
      | (.networkConfig.network // .network // "") as $network
      | (.networkConfig.subnetwork // .subnetwork // "") as $subnetwork
      | (.loggingConfig.componentConfig.enableComponents // []) as $logging_components
      | (.monitoringConfig.componentConfig.enableComponents // []) as $monitoring_components
      | (.fleet // {}) as $fleet
      | (.name == $name)
        and (.location == $region)
        and ([.locations[]?] | sort == $zones)
        and (.autopilot.enabled == true)
        and (.status == "RUNNING")
        and (($network | resource_name) == "risk-vpc")
        and (($subnetwork | resource_name) == $subnet)
        and ((.networkingMode // "VPC_NATIVE") == "VPC_NATIVE")
        and (.ipAllocationPolicy.useIpAliases == true)
        and ((.ipAllocationPolicy.stackType // "IPV4") == "IPV4")
        and (.ipAllocationPolicy.clusterSecondaryRangeName == $pod_range)
        and (.ipAllocationPolicy.servicesSecondaryRangeName == $service_range)
        and (($private_nodes | length) > 0)
        and all($private_nodes[]; . == true)
        and all($public_endpoints[]; . == true)
        and ((public_endpoint | type) == "string" and (public_endpoint | length) > 0)
        and (.privateClusterConfig.masterIpv4CidrBlock == $master_cidr)
        and all($global_access[]; . == false)
        and (($authorized_networks | length) > 0)
        and all($authorized_networks[];
          (.enabled == true)
          and ((.gcpPublicCidrsAccessEnabled // false) == false)
          and ([.cidrBlocks[]? | {cidrBlock, displayName}]
            == [{"cidrBlock": $admin_cidr, "displayName": "assessment-admin"}])
        )
        and ($datapath == "ADVANCED_DATAPATH")
        and (.releaseChannel.channel == "REGULAR")
        and (.workloadIdentityConfig.workloadPool == $workload_pool)
        and ((.loggingService // "logging.googleapis.com/kubernetes")
          == "logging.googleapis.com/kubernetes")
        and ($logging_components | sort == ["SYSTEM_COMPONENTS", "WORKLOADS"])
        and ((.monitoringService // "monitoring.googleapis.com/kubernetes")
          == "monitoring.googleapis.com/kubernetes")
        and ($monitoring_components == ["SYSTEM_COMPONENTS"])
        and ((node_service_account) == $node_service_account)
        and (($fleet.membership // "") == "")
        and (($fleet.project // "") == "")
        and (($fleet.preRegistered // false) == false)
    ' <<<"$cluster_json" >/dev/null || {
      printf 'Live cluster %s in %s does not match the frozen contract.\n' "$name" "$region" >&2
      exit 1
    }

  printf 'Verified live regional Autopilot cluster %s in %s.\n' "$name" "$region"
}

verify_cluster \
  gke-risk-usc1 us-central1 risk-usc1 \
  risk-usc1-pods risk-usc1-services 172.16.0.0/28 "$node_usc1" \
  us-central1-b us-central1-c us-central1-f

verify_cluster \
  gke-risk-use4 us-east4 risk-use4 \
  risk-use4-pods risk-use4-services 172.16.0.16/28 "$node_use4" \
  us-east4-a us-east4-b us-east4-c

gkehub_enabled="$(
  gcloud --configuration="$GCLOUD_CONFIGURATION" services list \
    --project="$PROJECT_ID" \
    --enabled \
    --filter='config.name=gkehub.googleapis.com' \
    --format='value(config.name)' \
    | tr -d '\r\n'
)"
if [[ "$gkehub_enabled" == "gkehub.googleapis.com" ]]; then
  memberships_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" container fleet memberships list \
      --project="$PROJECT_ID" \
      --format=json
  )"
  jq -e 'length == 0' <<<"$memberships_json" >/dev/null || {
    printf 'The dedicated project has unexpected Fleet memberships.\n' >&2
    exit 1
  }
  printf 'Verified that the enabled Fleet API has no memberships.\n'
else
  printf 'Fleet API is disabled; cluster records contain no Fleet membership.\n'
fi

printf 'Verified the complete two-cluster Terraform and live GKE contract.\n'

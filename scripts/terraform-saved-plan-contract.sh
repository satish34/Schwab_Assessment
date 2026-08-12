#!/usr/bin/env bash

# Shared, cloud-free contract for reviewed Terraform plans. The stack wrapper
# sources these functions; `--self-test` exercises the contract without GCP.

saved_plan_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

saved_plan_source_fingerprint() {
  local stack_dir="$1"

  [[ -d "$stack_dir" ]] || {
    printf 'Saved-plan source directory does not exist: %s\n' "$stack_dir" >&2
    return 1
  }

  (
    while IFS= read -r -d '' source_file; do
      source_relative="${source_file#"$stack_dir"/}"
      printf '%s\t%s\n' \
        "$source_relative" "$(saved_plan_sha256 "$source_file")"
    done < <(
      LC_ALL=C find "$stack_dir" -type f \
        ! -path "$stack_dir/.terraform/*" \
        \( -name '*.tf' -o -name '*.tf.json' \
          -o -name '*.tfvars' -o -name '*.tfvars.json' \
          -o -name '.terraform.lock.hcl' \) \
        -print0 | LC_ALL=C sort -z
    )

    for contract_file in \
      scripts/terraform-stack.sh \
      scripts/terraform-saved-plan-contract.sh; do
      [[ -f "$contract_file" ]] || {
        printf 'Saved-plan contract file is missing: %s\n' \
          "$contract_file" >&2
        exit 1
      }
      printf '%s\t%s\n' \
        "$contract_file" "$(saved_plan_sha256 "$contract_file")"
    done

    if [[ "$stack_dir" == "infra/10-global" ]]; then
      contract_file="scripts/remove-default-network.sh"
      [[ -f "$contract_file" ]] || {
        printf 'Saved-plan external executable is missing: %s\n' \
          "$contract_file" >&2
        exit 1
      }
      printf '%s\t%s\n' \
        "$contract_file" "$(saved_plan_sha256 "$contract_file")"
    fi
  ) | sha256sum | awk '{print $1}'
}

saved_plan_context_fingerprint() {
  local stack_dir="$1"
  local terraform_workspace="$2"

  jq -cn \
    --arg stack "$stack_dir" \
    --arg workspace "$terraform_workspace" \
    --arg project "${PROJECT_ID:-}" \
    --arg billing "${BILLING_ACCOUNT_ID:-}" \
    --arg configuration "${GCLOUD_CONFIGURATION:-}" \
    --arg operator "${SAVED_PLAN_OPERATOR:-}" \
    --arg domain "${DOMAIN_NAME:-}" \
    --arg admin_cidr "${ADMIN_CIDR:-}" \
    --arg armor "${ENABLE_CLOUD_ARMOR:-0}" \
    --arg binauthz "${ENABLE_BINARY_AUTHORIZATION:-0}" \
    --arg tf_cli_args "${TF_CLI_ARGS:-}" \
    --arg tf_cli_args_plan "${TF_CLI_ARGS_plan:-}" \
    --arg tf_cli_args_apply "${TF_CLI_ARGS_apply:-}" \
    --arg tf_cli_config_file "${TF_CLI_CONFIG_FILE:-}" \
    --arg tf_data_dir "${TF_DATA_DIR:-}" \
    --arg tf_workspace "${TF_WORKSPACE:-}" \
    --arg google_project "${GOOGLE_PROJECT:-}" \
    --arg google_cloud_project "${GOOGLE_CLOUD_PROJECT:-}" \
    --arg google_billing_project "${GOOGLE_BILLING_PROJECT:-}" \
    --arg google_region "${GOOGLE_REGION:-}" \
    --arg google_zone "${GOOGLE_ZONE:-}" \
    '{
      stack: $stack,
      workspace: $workspace,
      project: $project,
      billingAccount: $billing,
      gcloudConfiguration: $configuration,
      operator: $operator,
      domainName: $domain,
      adminCidr: $admin_cidr,
      enableCloudArmor: $armor,
      enableBinaryAuthorization: $binauthz,
      terraformEnvironment: {
        cliArgs: $tf_cli_args,
        planCliArgs: $tf_cli_args_plan,
        applyCliArgs: $tf_cli_args_apply,
        cliConfigFile: $tf_cli_config_file,
        dataDir: $tf_data_dir,
        requestedWorkspace: $tf_workspace
      },
      googleProviderEnvironment: {
        project: $google_project,
        cloudProject: $google_cloud_project,
        billingProject: $google_billing_project,
        region: $google_region,
        zone: $google_zone
      }
    }' | sha256sum | awk '{print $1}'
}

saved_plan_validate_common() {
  local plan_json_file="$1"

  jq -e '
    def permitted_action:
      . == ["no-op"] or . == ["read"] or . == ["create"] or . == ["update"];
    (.complete == true)
      and (.errored == false)
      and all(.resource_changes[]?; .change.actions | permitted_action)
      and all(.output_changes[]?; .actions | permitted_action)
      and (
        [
          .resource_changes[]?
          | select(.change.actions != ["no-op"] and .change.actions != ["read"])
        ] as $resource_changes
        | [
            .output_changes[]?
            | select(.actions != ["no-op"] and .actions != ["read"])
          ] as $output_changes
        | (($resource_changes | length) == 0 and ($output_changes | length) == 0)
          or (.applyable == true)
      )
  ' "$plan_json_file" >/dev/null
}

saved_plan_validate_bootstrap() {
  local plan_json_file="$1"
  local project_id="${PROJECT_ID:-}"
  local domain_name="${DOMAIN_NAME:-}"
  local billing_account_id="${BILLING_ACCOUNT_ID:-}"
  local enable_binary_authorization="${ENABLE_BINARY_AUTHORIZATION:-0}"

  [[ "$enable_binary_authorization" == "1" ]] \
    && enable_binary_authorization=true \
    || enable_binary_authorization=false

  jq -e \
    --arg project "$project_id" \
    --arg billing "$billing_account_id" \
    --arg domain "${domain_name%.}" \
    --argjson binauthz "$enable_binary_authorization" '
    def exact_bool($expected):
      if type == "boolean" then . == $expected
      elif type == "string" then ((. == "true") == $expected)
      else false end;
    def allowed_service:
      . as $service
      | ([
          "artifactregistry.googleapis.com",
          "bigquery.googleapis.com",
          "billingbudgets.googleapis.com",
          "cloudbuild.googleapis.com",
          "cloudbilling.googleapis.com",
          "cloudprofiler.googleapis.com",
          "cloudquotas.googleapis.com",
          "cloudtrace.googleapis.com",
          "clouderrorreporting.googleapis.com",
          "cloudresourcemanager.googleapis.com",
          "compute.googleapis.com",
          "container.googleapis.com",
          "iam.googleapis.com",
          "iamcredentials.googleapis.com",
          "logging.googleapis.com",
          "monitoring.googleapis.com",
          "serviceusage.googleapis.com",
          "storage.googleapis.com",
          "telemetry.googleapis.com"
        ] | index($service)) != null
        or (($domain != "") and (
          $service == "certificatemanager.googleapis.com"
          or $service == "dns.googleapis.com"
        ))
        or ($binauthz and (
          $service == "binaryauthorization.googleapis.com"
          or $service == "containeranalysis.googleapis.com"
        ));
    def resource_allowed:
      . as $resource
      | if ($resource.address | startswith("google_project_service.required[")) then
          ($resource.mode == "managed")
            and ($resource.type == "google_project_service")
            and ($resource.change.after.service | allowed_service)
            and ($resource.address == (
              "google_project_service.required["
              + ($resource.change.after.service | tojson) + "]"
            ))
            and ($resource.change.after.project == $project)
            and (
              if $resource.change.actions == ["no-op"] then
                (($resource.change.after.disable_dependent_services == false
                    or $resource.change.after.disable_dependent_services == null)
                  and ($resource.change.after.disable_on_destroy == false
                    or $resource.change.after.disable_on_destroy == null))
              else
                ($resource.change.after.disable_dependent_services == false)
                  and ($resource.change.after.disable_on_destroy == false)
              end
            )
        elif $resource.address == "data.google_project.current" then
          ($resource.mode == "data")
            and ($resource.type == "google_project")
            and ($resource.change.actions == ["read"]
              or $resource.change.actions == ["no-op"])
            and (($resource.change.after.project_id // $project) == $project)
        elif $resource.address == "google_billing_budget.safety" then
          ($resource.mode == "managed")
            and ($resource.type == "google_billing_budget")
            and ($resource.change.after.display_name
              == "Schwab Assessment - 30 USD Safety Budget")
            and ($resource.change.after.billing_account == $billing)
            and ($resource.change.after.budget_filter[0].calendar_period == "MONTH")
            and ($resource.change.after.amount[0].specified_amount[0].currency_code
              == "USD")
            and (($resource.change.after.amount[0].specified_amount[0].units
              | tostring) == "30")
            and (([
              $resource.change.after.threshold_rules[]
              | select(.spend_basis == "CURRENT_SPEND")
              | .threshold_percent
            ] | sort) == [0.5, 0.8, 0.9, 1])
        elif $resource.address
            == "google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity" then
          ($resource.mode == "managed")
            and ($resource.type == "google_cloud_quotas_quota_preference")
            and ($resource.change.after.parent == ("projects/" + $project))
            and ($resource.change.after.name == "compute-cpus-all-regions-96")
            and ($resource.change.after.service == "compute.googleapis.com")
            and ($resource.change.after.quota_id == "CPUS-ALL-REGIONS-per-project")
            and (($resource.change.after.quota_config[0].preferred_value | tostring)
              == "96")
        else
          false
        end;
    def output_allowed:
      . as $name
      | [
        "budget_name",
        "enabled_services",
        "gke_all_regions_cpu_quota",
        "project_id",
        "project_number"
      ] | index($name) != null;
    (.variables.project_id.value == $project)
      and (.variables.billing_account_id.value == $billing)
      and (.configuration.root_module.variables.billing_account_id.sensitive == true)
      and ((.variables.domain_name.value // "") == $domain)
      and (.variables.enable_binary_authorization.value | exact_bool($binauthz))
      and all(.resource_changes[]?; resource_allowed)
      and all((.output_changes // {}) | keys[]?; output_allowed)
  ' "$plan_json_file" >/dev/null
}

saved_plan_validate_global() {
  local plan_json_file="$1"
  local project_id="${PROJECT_ID:-}"
  local domain_name="${DOMAIN_NAME:-}"
  local configuration="${GCLOUD_CONFIGURATION:-}"
  local billing_account_id="${BILLING_ACCOUNT_ID:-}"
  local enable_binary_authorization="${ENABLE_BINARY_AUTHORIZATION:-0}"

  domain_name="${domain_name%.}"
  [[ "$enable_binary_authorization" == "1" ]] \
    && enable_binary_authorization=true \
    || enable_binary_authorization=false

  jq -e \
    --arg project "$project_id" \
    --arg domain "$domain_name" \
    --arg configuration "$configuration" \
    --arg billing "$billing_account_id" \
    --argjson binauthz "$enable_binary_authorization" '
    def exact_bool($expected):
      if type == "boolean" then . == $expected
      elif type == "string" then ((. == "true") == $expected)
      else false end;
    def allowed_pair:
      . as $resource
      | ([
          ["google_project.current", "google_project"],
          ["terraform_data.default_network_absent", "terraform_data"],
          ["google_project_default_service_accounts.defaults", "google_project_default_service_accounts"],
          ["google_compute_network.risk", "google_compute_network"],
          ["google_compute_subnetwork.cell[\"us-central1\"]", "google_compute_subnetwork"],
          ["google_compute_subnetwork.cell[\"us-east4\"]", "google_compute_subnetwork"],
          ["google_compute_global_address.risk", "google_compute_global_address"],
          ["google_compute_firewall.health_checks", "google_compute_firewall"],
          ["google_bigquery_dataset.risk_logs", "google_bigquery_dataset"],
          ["google_bigquery_dataset.platform_logs", "google_bigquery_dataset"],
          ["google_logging_project_sink.application_stdout", "google_logging_project_sink"],
          ["google_logging_project_sink.platform", "google_logging_project_sink"],
          ["google_bigquery_dataset_iam_member.sink_writer", "google_bigquery_dataset_iam_member"],
          ["google_bigquery_dataset_iam_member.platform_sink_writer", "google_bigquery_dataset_iam_member"],
          ["google_bigquery_dataset_iam_member.grafana_reader", "google_bigquery_dataset_iam_member"],
          ["google_artifact_registry_repository.risk", "google_artifact_registry_repository"],
          ["google_service_account.node[\"us-central1\"]", "google_service_account"],
          ["google_service_account.node[\"us-east4\"]", "google_service_account"],
          ["google_project_iam_member.node_runtime[\"us-central1\"]", "google_project_iam_member"],
          ["google_project_iam_member.node_runtime[\"us-east4\"]", "google_project_iam_member"],
          ["google_artifact_registry_repository_iam_member.node_image_pull[\"us-central1\"]", "google_artifact_registry_repository_iam_member"],
          ["google_artifact_registry_repository_iam_member.node_image_pull[\"us-east4\"]", "google_artifact_registry_repository_iam_member"],
          ["google_service_account.build", "google_service_account"],
          ["google_artifact_registry_repository_iam_member.build_image_push", "google_artifact_registry_repository_iam_member"],
          ["google_project_iam_member.build_logging", "google_project_iam_member"],
          ["google_service_account.grafana_reader", "google_service_account"],
          ["google_project_iam_member.grafana_reader[\"roles/bigquery.jobUser\"]", "google_project_iam_member"],
          ["google_project_iam_member.grafana_reader[\"roles/monitoring.viewer\"]", "google_project_iam_member"],
          ["google_project_iam_custom_role.grafana_project_reader", "google_project_iam_custom_role"],
          ["google_project_iam_member.grafana_project_reader", "google_project_iam_member"],
          ["google_service_account_iam_member.grafana_operator_impersonation", "google_service_account_iam_member"],
          ["google_service_account_iam_member.grafana_workload_identity", "google_service_account_iam_member"],
          ["google_service_account.app_a_caller", "google_service_account"],
          ["google_service_account_iam_member.app_a_caller_workload_identity", "google_service_account_iam_member"],
          ["google_project_iam_member.app_a_runtime[\"roles/cloudprofiler.agent\"]", "google_project_iam_member"],
          ["google_project_iam_member.app_a_runtime[\"roles/serviceusage.serviceUsageConsumer\"]", "google_project_iam_member"],
          ["google_project_iam_member.app_a_runtime[\"roles/telemetry.tracesWriter\"]", "google_project_iam_member"],
          ["google_service_account.app_b_telemetry", "google_service_account"],
          ["google_service_account_iam_member.app_b_telemetry_workload_identity", "google_service_account_iam_member"],
          ["google_project_iam_member.app_b_telemetry[\"roles/serviceusage.serviceUsageConsumer\"]", "google_project_iam_member"],
          ["google_project_iam_member.app_b_telemetry[\"roles/telemetry.tracesWriter\"]", "google_project_iam_member"],
          ["google_service_account.app_deployer[\"app_a\"]", "google_service_account"],
          ["google_service_account.app_deployer[\"app_b\"]", "google_service_account"],
          ["google_project_iam_member.app_deployer_cluster_viewer[\"app_a\"]", "google_project_iam_member"],
          ["google_project_iam_member.app_deployer_cluster_viewer[\"app_b\"]", "google_project_iam_member"],
          ["google_service_account_iam_member.app_deployer_user_impersonation[\"app_a\"]", "google_service_account_iam_member"],
          ["google_service_account_iam_member.app_deployer_user_impersonation[\"app_b\"]", "google_service_account_iam_member"],
          ["google_storage_bucket.build_source", "google_storage_bucket"],
          ["google_storage_bucket_iam_member.build_source_read", "google_storage_bucket_iam_member"],
          ["google_dns_managed_zone.risk[0]", "google_dns_managed_zone"],
          ["google_dns_record_set.public_ipv4[0]", "google_dns_record_set"],
          ["google_certificate_manager_dns_authorization.risk[0]", "google_certificate_manager_dns_authorization"],
          ["google_dns_record_set.certificate_authorization[0]", "google_dns_record_set"],
          ["google_certificate_manager_certificate.risk[0]", "google_certificate_manager_certificate"],
          ["google_certificate_manager_certificate_map.risk[0]", "google_certificate_manager_certificate_map"],
          ["google_certificate_manager_certificate_map_entry.risk[0]", "google_certificate_manager_certificate_map_entry"],
          ["google_binary_authorization_policy.assessment[0]", "google_binary_authorization_policy"]
        ] | any(.[]; . == [$resource.address, $resource.type]))
        and ($resource.mode == "managed");
    def create_unknown($field):
      (.change.actions == ["create"])
        and ((.change.after_unknown[$field] // false) != false);
    def exact_or_create_unknown($field; $expected):
      (.change.after[$field] == $expected) or create_unknown($field);
    def endswith_or_create_unknown($field; $suffix):
      ((.change.after[$field] | type) == "string"
        and (.change.after[$field] | endswith($suffix)))
        or create_unknown($field);
    def exact_member($role; $member):
      (.change.after.role == $role) and exact_or_create_unknown("member"; $member);
    def project_iam_valid:
      . as $resource
      | ($resource.change.after.project == $project
        or ($resource | create_unknown("project")))
      and if ($resource.address | startswith("google_project_iam_member.node_runtime[")) then
          ($resource.address | capture("node_runtime\\[\\\"(?<region>[^\\\"]+)\\\"\\]").region) as $region
          | ($region == "us-central1" or $region == "us-east4")
          and ($resource | exact_member(
            "roles/container.defaultNodeServiceAccount";
            "serviceAccount:" + (if $region == "us-central1" then
              "risk-gke-usc1-nodes" else "risk-gke-use4-nodes" end)
              + "@" + $project + ".iam.gserviceaccount.com"
          ))
        elif $resource.address == "google_project_iam_member.build_logging" then
          ($resource | exact_member("roles/logging.logWriter";
            "serviceAccount:risk-cloud-build@" + $project + ".iam.gserviceaccount.com"))
        elif ($resource.address | startswith("google_project_iam_member.grafana_reader[")) then
          ($resource.address == ("google_project_iam_member.grafana_reader["
            + ($resource.change.after.role | tojson) + "]"))
          and (($resource.change.after.role == "roles/bigquery.jobUser")
            or ($resource.change.after.role == "roles/monitoring.viewer"))
          and ($resource | exact_or_create_unknown("member";
            "serviceAccount:grafana-reader@" + $project + ".iam.gserviceaccount.com"))
        elif $resource.address == "google_project_iam_member.grafana_project_reader" then
          ($resource | exact_member("projects/" + $project + "/roles/grafanaProjectReader";
            "serviceAccount:grafana-reader@" + $project + ".iam.gserviceaccount.com"))
        elif ($resource.address | startswith("google_project_iam_member.app_a_runtime[")) then
          ($resource.address == ("google_project_iam_member.app_a_runtime["
            + ($resource.change.after.role | tojson) + "]"))
          and (["roles/cloudprofiler.agent", "roles/serviceusage.serviceUsageConsumer", "roles/telemetry.tracesWriter"]
            | index($resource.change.after.role) != null)
          and ($resource | exact_or_create_unknown("member";
            "serviceAccount:currency-app-a-caller@" + $project + ".iam.gserviceaccount.com"))
        elif ($resource.address | startswith("google_project_iam_member.app_b_telemetry[")) then
          ($resource.address == ("google_project_iam_member.app_b_telemetry["
            + ($resource.change.after.role | tojson) + "]"))
          and (["roles/serviceusage.serviceUsageConsumer", "roles/telemetry.tracesWriter"]
            | index($resource.change.after.role) != null)
          and ($resource | exact_or_create_unknown("member";
            "serviceAccount:currency-app-b-telemetry@" + $project + ".iam.gserviceaccount.com"))
        elif ($resource.address | startswith("google_project_iam_member.app_deployer_cluster_viewer[")) then
          ($resource.address | capture("cluster_viewer\\[\\\"(?<app>app_[ab])\\\"\\]").app) as $app
          | ($resource | exact_member("roles/container.clusterViewer";
            "serviceAccount:currency-app-" + (if $app == "app_a" then "a" else "b" end)
              + "-deployer@" + $project + ".iam.gserviceaccount.com"))
        else false end;
    def repository_iam_valid:
      . as $resource
      | ($resource.change.after.project == $project
        or ($resource | create_unknown("project")))
      and ($resource.change.after.location == "us-central1"
        or ($resource | create_unknown("location")))
      and (($resource.change.after.repository == "risk")
        or (($resource.change.after.repository | type) == "string"
          and ($resource.change.after.repository | endswith("/repositories/risk")))
        or ($resource | create_unknown("repository")))
      and if $resource.address == "google_artifact_registry_repository_iam_member.build_image_push" then
          ($resource | exact_member("roles/artifactregistry.writer";
            "serviceAccount:risk-cloud-build@" + $project + ".iam.gserviceaccount.com"))
        else
          ($resource.address | capture("node_image_pull\\[\\\"(?<region>[^\\\"]+)\\\"\\]").region) as $region
          | ($region == "us-central1" or $region == "us-east4")
          and ($resource | exact_member("roles/artifactregistry.reader";
            "serviceAccount:" + (if $region == "us-central1" then
              "risk-gke-usc1-nodes" else "risk-gke-use4-nodes" end)
              + "@" + $project + ".iam.gserviceaccount.com"))
        end;
    def service_account_iam_valid:
      . as $resource
      | if $resource.address == "google_service_account_iam_member.grafana_operator_impersonation" then
          ($resource | exact_member("roles/iam.serviceAccountTokenCreator"; "user:satish.cse7@gmail.com"))
          and ($resource | endswith_or_create_unknown("service_account_id";
            "/serviceAccounts/grafana-reader@" + $project + ".iam.gserviceaccount.com"))
        elif $resource.address == "google_service_account_iam_member.grafana_workload_identity" then
          ($resource | exact_member("roles/iam.workloadIdentityUser";
            "serviceAccount:" + $project + ".svc.id.goog[currency-observability/currency-grafana]"))
          and ($resource | endswith_or_create_unknown("service_account_id";
            "/serviceAccounts/grafana-reader@" + $project + ".iam.gserviceaccount.com"))
        elif $resource.address == "google_service_account_iam_member.app_a_caller_workload_identity" then
          ($resource | exact_member("roles/iam.workloadIdentityUser";
            "serviceAccount:" + $project + ".svc.id.goog[currency-app-a/app-a-gateway]"))
          and ($resource | endswith_or_create_unknown("service_account_id";
            "/serviceAccounts/currency-app-a-caller@" + $project + ".iam.gserviceaccount.com"))
        elif $resource.address == "google_service_account_iam_member.app_b_telemetry_workload_identity" then
          ($resource | exact_member("roles/iam.workloadIdentityUser";
            "serviceAccount:" + $project + ".svc.id.goog[currency-app-b/app-b-engine]"))
          and ($resource | endswith_or_create_unknown("service_account_id";
            "/serviceAccounts/currency-app-b-telemetry@" + $project + ".iam.gserviceaccount.com"))
        else
          ($resource.address | capture("user_impersonation\\[\\\"(?<app>app_[ab])\\\"\\]").app) as $app
          | ($resource | exact_member("roles/iam.serviceAccountTokenCreator"; "user:satish.cse7@gmail.com"))
          and ($resource | endswith_or_create_unknown("service_account_id";
            "/serviceAccounts/currency-app-" + (if $app == "app_a" then "a" else "b" end)
              + "-deployer@" + $project + ".iam.gserviceaccount.com"))
        end;
    def subnetwork_valid:
      . as $resource
      | ($resource.address | capture("cell\\[\\\"(?<region>[^\\\"]+)\\\"\\]").region) as $region
      | ($region == "us-central1" or $region == "us-east4")
      and ($resource.change.after.project == $project
        or ($resource | create_unknown("project")))
      and ($resource.change.after.region == $region)
      and ($resource.change.after.name == (if $region == "us-central1" then "risk-usc1" else "risk-use4" end))
      and ($resource.change.after.ip_cidr_range == (if $region == "us-central1" then "10.10.0.0/20" else "10.11.0.0/20" end))
      and ($resource.change.after.private_ip_google_access == true)
      and ($resource.change.after.stack_type == "IPV4_ONLY")
      and ($resource | endswith_or_create_unknown("network";
        "/projects/" + $project + "/global/networks/risk-vpc"))
      and ($resource.change.after.log_config == [{
        aggregation_interval: "INTERVAL_1_MIN",
        filter_expr: "true",
        flow_sampling: 0.05,
        metadata: "EXCLUDE_ALL_METADATA",
        metadata_fields: null
      }])
      and (([$resource.change.after.secondary_ip_range[]
        | [.range_name, .ip_cidr_range]] | sort) == (if $region == "us-central1" then
          [["risk-usc1-pods", "10.20.0.0/16"], ["risk-usc1-services", "10.30.0.0/20"]]
        else
          [["risk-use4-pods", "10.21.0.0/16"], ["risk-use4-services", "10.31.0.0/20"]]
        end));
    def service_account_valid:
      . as $resource
      | $resource.change.after.account_id as $account_id
      | ($resource.change.after.project == $project
        or ($resource | create_unknown("project")))
      and (if ($resource.address | startswith("google_service_account.node[")) then
          ($resource.address | capture("node\\[\\\"(?<region>[^\\\"]+)\\\"\\]").region) as $region
          | $account_id == (if $region == "us-central1" then
              "risk-gke-usc1-nodes" elif $region == "us-east4" then
              "risk-gke-use4-nodes" else "" end)
        elif $resource.address == "google_service_account.build" then
          $account_id == "risk-cloud-build"
        elif $resource.address == "google_service_account.grafana_reader" then
          $account_id == "grafana-reader"
        elif $resource.address == "google_service_account.app_a_caller" then
          $account_id == "currency-app-a-caller"
        elif $resource.address == "google_service_account.app_b_telemetry" then
          $account_id == "currency-app-b-telemetry"
        elif ($resource.address | startswith("google_service_account.app_deployer[")) then
          ($resource.address | capture("app_deployer\\[\\\"(?<app>app_[ab])\\\"\\]").app) as $app
          | $account_id == (if $app == "app_a" then
              "currency-app-a-deployer" else "currency-app-b-deployer" end)
        else false end);
    def critical_after_valid:
      . as $resource
      | $resource.change.after as $after
      | if $resource.type == "google_project_iam_member" then project_iam_valid
        elif $resource.type == "google_artifact_registry_repository_iam_member" then repository_iam_valid
        elif $resource.type == "google_service_account_iam_member" then service_account_iam_valid
        elif $resource.address == "google_bigquery_dataset_iam_member.grafana_reader" then
          ($resource | exact_member("roles/bigquery.dataViewer";
            "serviceAccount:grafana-reader@" + $project + ".iam.gserviceaccount.com"))
          and ($after.project == $project or ($resource | create_unknown("project")))
          and ($after.dataset_id == "risk_logs" or ($resource | create_unknown("dataset_id")))
        elif ($resource.address == "google_bigquery_dataset_iam_member.sink_writer"
            or $resource.address == "google_bigquery_dataset_iam_member.platform_sink_writer") then
          ($after.role == "roles/bigquery.dataEditor")
            and ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.dataset_id == (if $resource.address
              == "google_bigquery_dataset_iam_member.sink_writer" then
              "risk_logs" else "currency_platform_logs" end)
              or ($resource | create_unknown("dataset_id")))
            and ((($after.member | type) == "string"
              and ($after.member | startswith("serviceAccount:service-"))
              and ($after.member | endswith("@gcp-sa-logging.iam.gserviceaccount.com")))
              or ($resource | create_unknown("member")))
        elif $resource.address == "google_storage_bucket_iam_member.build_source_read" then
          ($resource | exact_member("roles/storage.objectViewer";
            "serviceAccount:risk-cloud-build@" + $project + ".iam.gserviceaccount.com"))
          and (($after.bucket == ($project + "_cloudbuild"))
            or ($after.bucket == ("b/" + $project + "_cloudbuild"))
            or ($resource | create_unknown("bucket")))
        elif $resource.address == "google_compute_network.risk" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.name == "risk-vpc") and ($after.auto_create_subnetworks == false)
            and ($after.routing_mode == "GLOBAL")
        elif $resource.type == "google_compute_subnetwork" then subnetwork_valid
        elif $resource.address == "google_compute_firewall.health_checks" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.name == "risk-allow-gfe-to-app-a") and ($after.direction == "INGRESS")
            and ($after.priority == 1000)
            and (($after.source_ranges | sort) == ["130.211.0.0/22", "35.191.0.0/16"])
            and ($after.allow == [{ports:["8080"], protocol:"tcp"}])
            and ($resource | endswith_or_create_unknown("network";
              "/projects/" + $project + "/global/networks/risk-vpc"))
            and (((($after.target_service_accounts // []) | sort) == [
                "risk-gke-usc1-nodes@" + $project + ".iam.gserviceaccount.com",
                "risk-gke-use4-nodes@" + $project + ".iam.gserviceaccount.com"
              ]) or ($resource | create_unknown("target_service_accounts")))
        elif $resource.address == "google_compute_global_address.risk" then
          ($after.project == $project) and ($after.name == "risk-global-ip")
            and ($after.address_type == "EXTERNAL")
            and (($after.ip_version == "IPV4") or ($after.ip_version == ""))
        elif $resource.address == "google_artifact_registry_repository.risk" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.location == "us-central1") and ($after.repository_id == "risk")
            and ($after.format == "DOCKER") and ($after.docker_config == [{immutable_tags:true}])
        elif $resource.address == "google_project.current" then
          ($after.project_id == $project) and ($after.name == "Schwab Assessment")
            and ($after.billing_account == $billing)
            and ($after.auto_create_network == false) and ($after.deletion_policy == "ABANDON")
        elif $resource.address == "google_project_default_service_accounts.defaults" then
          ($after.project == $project) and ($after.action == "DEPRIVILEGE")
            and ($after.restore_policy == "NONE")
        elif $resource.address == "google_storage_bucket.build_source" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.name == ($project + "_cloudbuild")) and ($after.location == "US")
            and ($after.storage_class == "STANDARD")
            and ($after.uniform_bucket_level_access == true)
            and ($after.public_access_prevention == "enforced")
        elif $resource.address == "google_bigquery_dataset.risk_logs" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.dataset_id == "risk_logs") and ($after.location == "US")
        elif $resource.address == "google_bigquery_dataset.platform_logs" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.dataset_id == "currency_platform_logs") and ($after.location == "US")
            and ($after.default_partition_expiration_ms == 2592000000)
            and (($after.max_time_travel_hours | tonumber) == 48)
        elif $resource.address == "google_logging_project_sink.application_stdout" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.name == "risk-app-stdout-to-bigquery")
            and ($after.destination == "bigquery.googleapis.com/projects/" + $project + "/datasets/risk_logs")
            and ($after.unique_writer_identity == true)
            and ($after.bigquery_options == [{use_partitioned_tables:true}])
            and ($after.filter | contains("namespace_name=\"currency-app-a\""))
            and ($after.filter | contains("namespace_name=\"currency-app-b\""))
            and ($after.filter | contains("log_id(\"stdout\")"))
            and ($after.filter | contains("jsonPayload.service=\"app-a-gateway\""))
            and ($after.filter | contains("jsonPayload.service=\"app-b-engine\""))
        elif $resource.address == "google_logging_project_sink.platform" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.name == "currency-platform-to-bigquery")
            and ($after.destination == "bigquery.googleapis.com/projects/" + $project + "/datasets/currency_platform_logs")
            and ($after.unique_writer_identity == true)
            and ($after.bigquery_options == [{use_partitioned_tables:true}])
            and ($after.filter | contains("resource.type=\"k8s_control_plane_component\""))
            and ($after.filter | contains("resource.type=\"k8s_node\""))
            and ($after.filter | contains("sample(insertId, 0.10)"))
            and ($after.filter | contains("NOT (log_id(\"stdout\") OR log_id(\"stderr\"))"))
            and ($after.filter | contains("compute.googleapis.com/vpc_flows"))
            and ($after.filter | contains("compute.googleapis.com/firewall"))
            and ($after.filter | contains("compute.googleapis.com/healthchecks"))
            and ($after.filter | contains("resource.type=\"http_load_balancer\""))
        elif $resource.type == "google_service_account" then service_account_valid
        elif $resource.address == "google_project_iam_custom_role.grafana_project_reader" then
          ($after.project == $project or ($resource | create_unknown("project")))
            and ($after.role_id == "grafanaProjectReader")
            and (($after.permissions | sort) == ["resourcemanager.projects.get"])
        elif $resource.type == "google_dns_managed_zone" then
          ($domain != "") and ($after.name == "risk-public-zone")
            and ($after.dns_name == ($domain + ".")) and ($after.visibility == "public")
        elif $resource.address == "google_dns_record_set.public_ipv4[0]" then
          ($domain != "") and ($after.name == ($domain + "."))
            and ($after.type == "A") and ($after.ttl == 300)
        elif $resource.type == "google_certificate_manager_dns_authorization" then
          ($domain != "") and ($after.name == "risk-dns-auth") and ($after.domain == $domain)
        elif $resource.type == "google_certificate_manager_certificate" then
          ($domain != "") and ($after.name == "risk-cert")
            and ($after.managed[0].domains == [$domain])
        elif $resource.type == "google_certificate_manager_certificate_map" then
          ($domain != "") and ($after.name == "risk-cert-map")
        elif $resource.type == "google_certificate_manager_certificate_map_entry" then
          ($domain != "") and ($after.name == "risk-domain") and ($after.hostname == $domain)
        elif $resource.type == "google_binary_authorization_policy" then
          $binauthz and ($after.global_policy_evaluation_mode == "ENABLE")
            and ($after.default_admission_rule == [{
              enforcement_mode:"ENFORCED_BLOCK_AND_AUDIT_LOG",
              evaluation_mode:"ALWAYS_DENY",
              require_attestations_by:[]
            }])
            and (([$after.admission_whitelist_patterns[].name_pattern] | sort) == [
              "us-central1-docker.pkg.dev/" + $project + "/risk/app-a",
              "us-central1-docker.pkg.dev/" + $project + "/risk/app-b",
              "us-central1-docker.pkg.dev/" + $project + "/risk/grafana-evidence"
            ])
        else true end;
    def output_allowed:
      . as $name
      | [
          "app_a_caller_service_account_email", "app_b_telemetry_service_account_email",
          "app_deployer_service_account_emails", "artifact_registry_repository",
          "bigquery_dataset_id", "binary_authorization_enabled",
          "binary_authorization_policy_id", "build_service_account_email",
          "build_source_bucket", "certificate_map_id",
          "default_service_accounts_deprivileged", "dns_name_servers", "domain_name",
          "global_address_name", "global_ipv4_address", "grafana_reader_email",
          "health_firewall_name", "log_sink_name", "log_sink_writer_identity",
          "network_name", "network_self_link", "node_service_account_emails",
          "project_id", "project_number", "secondary_ranges", "subnetwork_names",
          "subnetwork_self_links"
        ] | index($name) != null;
    (.variables.project_id.value == $project)
      and (.variables.billing_account_id.value == $billing)
      and (.configuration.root_module.variables.billing_account_id.sensitive == true)
      and (.variables.gcloud_configuration.value == $configuration)
      and ((.variables.domain_name.value // "") == $domain)
      and (.variables.enable_binary_authorization.value | exact_bool($binauthz))
      and ([.resource_changes[]? | select((allowed_pair | not)) | .address] as $bad
        | if ($bad | length) == 0 then true
          else ("unapproved address/type: " + ($bad | join(", ")) | debug) | false end)
      and ([.resource_changes[]? | select((critical_after_valid | not)) | .address] as $bad
        | if ($bad | length) == 0 then true
          else ("invalid critical after-state: " + ($bad | join(", ")) | debug) | false end)
      and all((.output_changes // {}) | keys[]?; output_allowed)
  ' "$plan_json_file" >/dev/null
}

saved_plan_validate_load_balancer() {
  local plan_json_file="$1"
  local project_id="${PROJECT_ID:-}"
  local domain_name="${DOMAIN_NAME:-}"
  local enable_cloud_armor="${ENABLE_CLOUD_ARMOR:-0}"

  [[ "$enable_cloud_armor" == "1" ]] \
    && enable_cloud_armor=true \
    || enable_cloud_armor=false

  jq -e \
    --arg project "$project_id" \
    --arg domain "${domain_name%.}" \
    --argjson armor "$enable_cloud_armor" '
    def exact_bool($expected):
      if type == "boolean" then . == $expected
      elif type == "string" then ((. == "true") == $expected)
      else false end;
    def allowed_pair:
      . as $resource
      | ([
          ["data.terraform_remote_state.global", "terraform_remote_state", "data"],
          ["terraform_data.global_contract", "terraform_data", "managed"],
          ["data.google_compute_network_endpoint_group.app_a[\"us-central1-b\"]", "google_compute_network_endpoint_group", "data"],
          ["data.google_compute_network_endpoint_group.app_a[\"us-central1-c\"]", "google_compute_network_endpoint_group", "data"],
          ["data.google_compute_network_endpoint_group.app_a[\"us-central1-f\"]", "google_compute_network_endpoint_group", "data"],
          ["data.google_compute_network_endpoint_group.app_a[\"us-east4-a\"]", "google_compute_network_endpoint_group", "data"],
          ["data.google_compute_network_endpoint_group.app_a[\"us-east4-b\"]", "google_compute_network_endpoint_group", "data"],
          ["data.google_compute_network_endpoint_group.app_a[\"us-east4-c\"]", "google_compute_network_endpoint_group", "data"],
          ["terraform_data.neg_contract", "terraform_data", "managed"],
          ["google_compute_health_check.app_a_cell", "google_compute_health_check", "managed"],
          ["google_compute_backend_service.app_a", "google_compute_backend_service", "managed"],
          ["google_compute_url_map.application", "google_compute_url_map", "managed"],
          ["google_compute_target_http_proxy.application[0]", "google_compute_target_http_proxy", "managed"],
          ["google_compute_global_forwarding_rule.http[0]", "google_compute_global_forwarding_rule", "managed"],
          ["google_compute_target_https_proxy.application[0]", "google_compute_target_https_proxy", "managed"],
          ["google_compute_global_forwarding_rule.https[0]", "google_compute_global_forwarding_rule", "managed"],
          ["google_compute_security_policy.currency_edge[0]", "google_compute_security_policy", "managed"]
        ] | any(.[]; . == [$resource.address, $resource.type, $resource.mode]));
    def create_unknown($field):
      (.change.actions == ["create"])
        and ((.change.after_unknown[$field] // false) != false);
    def endswith_or_create_unknown($field; $suffix):
      ((.change.after[$field] | type) == "string"
        and (.change.after[$field] | endswith($suffix)))
        or create_unknown($field);
    def neg_valid:
      . as $resource
      | ($resource.address | capture("app_a\\[\\\"(?<zone>[^\\\"]+)\\\"\\]").zone) as $zone
      | ($zone == "us-central1-b" or $zone == "us-central1-c"
          or $zone == "us-central1-f" or $zone == "us-east4-a"
          or $zone == "us-east4-b" or $zone == "us-east4-c")
      and ($resource.change.after.zone == $zone)
      and ($resource.change.after.project == $project)
      and ($resource.change.after.name == (if ($zone | startswith("us-central1"))
        then "app-a-neg-usc1" else "app-a-neg-use4" end))
      and ($resource.change.after.network_endpoint_type == "GCE_VM_IP_PORT")
      and ($resource.change.after.network | endswith("/networks/risk-vpc"))
      and ($resource.change.after.subnetwork | endswith("/subnetworks/"
        + (if ($zone | startswith("us-central1")) then "risk-usc1" else "risk-use4" end)))
      and (($resource.change.after.size | tonumber) >= 1);
    def health_check_valid:
      .change.after as $after
      | ($after.project == $project)
        and ($after.name == "risk-app-a-cell-health")
        and ($after.check_interval_sec == 5)
        and ($after.timeout_sec == 2)
        and ($after.unhealthy_threshold == 2)
        and ($after.healthy_threshold == 3)
        and ($after.http_health_check == [{
          host:"", port:0, port_name:"", port_specification:"USE_SERVING_PORT",
          proxy_header:"NONE", request_path:"/health/cell", response:""
        }])
        and ($after.log_config == [{enable:true}]);
    def backend_valid:
      .change.after as $after
      | ($after.project == $project)
        and ($after.name == "risk-app-a-gateway-backend")
        and ($after.protocol == "HTTP")
        and ($after.load_balancing_scheme == "EXTERNAL_MANAGED")
        and ($after.locality_lb_policy == "ROUND_ROBIN")
        and ($after.session_affinity == "NONE")
        and ($after.timeout_sec == 10)
        and ($after.connection_draining_timeout_sec == 30)
        and (((($after.health_checks // []) | length) == 1
          and ($after.health_checks[0] | type) == "string"
          and ($after.health_checks[0] | endswith("/healthChecks/risk-app-a-cell-health")))
          or (. | create_unknown("health_checks")))
        and (if $armor then
          (. | endswith_or_create_unknown("security_policy";
            "/securityPolicies/currency-edge-waf"))
          and ($after.log_config[0].sample_rate == 1)
        else
          (($after.security_policy == null) or ($after.security_policy == ""))
          and ($after.log_config[0].sample_rate == 0.05)
        end)
        and ($after.log_config[0].enable == true)
        and (($after.backend | length) == 6)
        and all($after.backend[];
          (.balancing_mode == "RATE")
            and (.max_rate_per_endpoint == 20)
            and (.capacity_scaler == 1)
        )
        and (([$after.backend[].group | capture("/zones/(?<zone>[^/]+)/networkEndpointGroups/(?<neg>[^/]+)$")
          | [.zone, .neg]] | sort) == [
            ["us-central1-b", "app-a-neg-usc1"],
            ["us-central1-c", "app-a-neg-usc1"],
            ["us-central1-f", "app-a-neg-usc1"],
            ["us-east4-a", "app-a-neg-use4"],
            ["us-east4-b", "app-a-neg-use4"],
            ["us-east4-c", "app-a-neg-use4"]
          ]);
    def armor_valid:
      .change.after as $after
      | $armor
        and ($after.project == $project)
        and ($after.name == "currency-edge-waf")
        and ($after.type == "CLOUD_ARMOR")
        and (($after.rule | length) == 4)
        and (([$after.rule[] | [.priority, .action, .preview]] | sort_by(.[0])) == [
          [1000, "deny(403)", true],
          [1010, "deny(403)", true],
          [2000, "rate_based_ban", false],
          [2147483647, "allow", false]
        ])
        and (($after.rule | map(select(.priority == 1000)) | first)
          .match[0].expr[0].expression
          == "evaluatePreconfiguredWaf(\u0027sqli-v422-stable\u0027, {\u0027sensitivity\u0027: 1})")
        and (($after.rule | map(select(.priority == 1010)) | first)
          .match[0].expr[0].expression
          == "evaluatePreconfiguredWaf(\u0027xss-v422-stable\u0027, {\u0027sensitivity\u0027: 1})")
        and (($after.rule | map(select(.priority == 2000)) | first)
          .rate_limit_options[0] as $rate
          | ($rate.conform_action == "allow")
            and ($rate.exceed_action == "deny(429)")
            and ($rate.enforce_on_key == "IP")
            and ($rate.ban_duration_sec == 60)
            and ($rate.rate_limit_threshold == [{count:120, interval_sec:60}])
            and ($rate.ban_threshold == [{count:600, interval_sec:60}]))
        and all($after.rule[] | .match[0].config[]?.src_ip_ranges[]?; . == "*");
    def critical_after_valid:
      . as $resource
      | $resource.change.after as $after
      | if $resource.address == "data.terraform_remote_state.global" then
          ($resource.change.actions == ["read"] or $resource.change.actions == ["no-op"])
        elif $resource.type == "google_compute_network_endpoint_group" then neg_valid
        elif $resource.address == "terraform_data.global_contract" then
          (($after.input // $project) == $project)
        elif $resource.address == "terraform_data.neg_contract" then
          (($after.input | keys | sort) == [
            "us-central1-b", "us-central1-c", "us-central1-f",
            "us-east4-a", "us-east4-b", "us-east4-c"
          ])
        elif $resource.address == "google_compute_health_check.app_a_cell" then health_check_valid
        elif $resource.address == "google_compute_backend_service.app_a" then backend_valid
        elif $resource.address == "google_compute_url_map.application" then
          ($after.project == $project) and ($after.name == "risk-app-a-gateway-map")
            and ($resource | endswith_or_create_unknown("default_service";
              "/backendServices/risk-app-a-gateway-backend"))
        elif $resource.address == "google_compute_target_http_proxy.application[0]" then
          ($after.project == $project) and ($after.name == "risk-app-a-http-proxy")
            and ($resource | endswith_or_create_unknown("url_map";
              "/urlMaps/risk-app-a-gateway-map"))
        elif $resource.address == "google_compute_global_forwarding_rule.http[0]" then
          ($after.project == $project) and ($after.name == "risk-app-a-http")
            and ($after.ip_protocol == "TCP")
            and (($after.port_range == "80") or ($after.port_range == "80-80"))
            and ($after.load_balancing_scheme == "EXTERNAL_MANAGED")
            and ($after.network_tier == "PREMIUM")
            and ($resource | endswith_or_create_unknown("target";
              "/targetHttpProxies/risk-app-a-http-proxy"))
        elif $resource.address == "google_compute_target_https_proxy.application[0]" then
          ($after.project == $project) and ($after.name == "risk-app-a-https-proxy")
            and ($resource | endswith_or_create_unknown("url_map";
              "/urlMaps/risk-app-a-gateway-map"))
            and ($resource | endswith_or_create_unknown("certificate_map";
              "/certificateMaps/risk-cert-map"))
            and ($after.quic_override == "NONE")
        elif $resource.address == "google_compute_global_forwarding_rule.https[0]" then
          ($after.project == $project) and ($after.name == "risk-app-a-https")
            and ($after.ip_protocol == "TCP")
            and (($after.port_range == "443") or ($after.port_range == "443-443"))
            and ($after.load_balancing_scheme == "EXTERNAL_MANAGED")
            and ($after.network_tier == "PREMIUM")
            and ($resource | endswith_or_create_unknown("target";
              "/targetHttpsProxies/risk-app-a-https-proxy"))
        elif $resource.address == "google_compute_security_policy.currency_edge[0]" then armor_valid
        else false end;
    def output_allowed:
      . as $name
      | [
          "backend_request_log_sample_rate", "backend_service_name",
          "backend_service_self_link", "cloud_armor_enabled", "forwarding_rule_names",
          "global_ipv4_address", "health_check_name", "neg_backends",
          "public_endpoint", "security_policy_name", "tls_enabled"
        ] | index($name) != null;
    (.variables.project_id.value == $project)
      and (.variables.enable_cloud_armor.value | exact_bool($armor))
      and ([.resource_changes[]? | select(.mode == "managed") | .address] as $managed
        | ($managed | length) == ($managed | unique | length)
        and if ($managed | length) == 0 then true else
          ($managed | sort) == (([
            "terraform_data.global_contract",
            "terraform_data.neg_contract",
            "google_compute_health_check.app_a_cell",
            "google_compute_backend_service.app_a",
            "google_compute_url_map.application"
          ] + (if $domain == "" then [
            "google_compute_target_http_proxy.application[0]",
            "google_compute_global_forwarding_rule.http[0]"
          ] else [
            "google_compute_target_https_proxy.application[0]",
            "google_compute_global_forwarding_rule.https[0]"
          ] end) + (if $armor then [
            "google_compute_security_policy.currency_edge[0]"
          ] else [] end)) | sort)
        end)
      and (.output_changes.tls_enabled.after == ($domain != ""))
      and (.output_changes.public_endpoint.after == (if $domain == "" then
        "http://" + .output_changes.global_ipv4_address.after
      else
        "https://" + $domain
      end))
      and ([.resource_changes[]? | select((allowed_pair | not)) | .address] as $bad
        | if ($bad | length) == 0 then true
          else ("unapproved address/type: " + ($bad | join(", ")) | debug) | false end)
      and ([.resource_changes[]? | select((critical_after_valid | not)) | .address] as $bad
        | if ($bad | length) == 0 then true
          else ("invalid critical after-state: " + ($bad | join(", ")) | debug) | false end)
      and all((.output_changes // {}) | keys[]?; output_allowed)
  ' "$plan_json_file" >/dev/null
}

saved_plan_validate_json() {
  local stack_dir="$1"
  local plan_json_file="$2"

  saved_plan_validate_common "$plan_json_file" || {
    printf '%s saved plan was refused: it is incomplete, errored, non-applyable, or contains a delete/replacement action.\n' \
      "$stack_dir" >&2
    return 1
  }

  case "$stack_dir" in
    infra/00-bootstrap)
      saved_plan_validate_bootstrap "$plan_json_file"
      ;;
    infra/10-global)
      saved_plan_validate_global "$plan_json_file"
      ;;
    infra/30-lb)
      saved_plan_validate_load_balancer "$plan_json_file"
      ;;
    *)
      printf 'No reviewed-plan contract exists for %s.\n' "$stack_dir" >&2
      return 1
      ;;
  esac || {
    printf '%s saved plan was refused: an address, resource type, variable, output, or security-critical after-state is outside the approved stack contract.\n' \
      "$stack_dir" >&2
    return 1
  }
}

saved_plan_write_metadata() {
  local stack_dir="$1"
  local plan_file="$2"
  local metadata_file="$3"
  local project_id="$4"
  local configuration="$5"
  local operator="$6"
  local head_sha="$7"
  local source_sha="$8"
  local context_sha="$9"
  local created_at="${10:-$(date +%s)}"
  local max_age_seconds=1800
  local expires_at=$((created_at + max_age_seconds))
  local plan_sha

  plan_sha="$(saved_plan_sha256 "$plan_file")"
  jq -n \
    --argjson schema_version 1 \
    --arg stack "$stack_dir" \
    --arg plan_file "$(basename "$plan_file")" \
    --arg project "$project_id" \
    --arg configuration "$configuration" \
    --arg operator "$operator" \
    --arg head "$head_sha" \
    --arg source "$source_sha" \
    --arg context "$context_sha" \
    --arg plan "$plan_sha" \
    --argjson created "$created_at" \
    --argjson expires "$expires_at" \
    '{
      schemaVersion: $schema_version,
      stack: $stack,
      planFile: $plan_file,
      projectId: $project,
      gcloudConfiguration: $configuration,
      operator: $operator,
      headSha: $head,
      sourceSha256: $source,
      contextSha256: $context,
      planSha256: $plan,
      createdAtEpoch: $created,
      expiresAtEpoch: $expires
    }' >"$metadata_file"
}

saved_plan_verify_metadata() {
  local stack_dir="$1"
  local plan_file="$2"
  local metadata_file="$3"
  local project_id="$4"
  local configuration="$5"
  local operator="$6"
  local head_sha="$7"
  local source_sha="$8"
  local context_sha="$9"
  local now="${10:-$(date +%s)}"
  local max_age_seconds=1800
  local plan_sha

  [[ -f "$plan_file" && -f "$metadata_file" ]] || {
    printf 'No reviewed plan is available for %s. Run its plan target first.\n' \
      "$stack_dir" >&2
    return 1
  }
  plan_sha="$(saved_plan_sha256 "$plan_file")"

  jq -e \
    --arg stack "$stack_dir" \
    --arg plan_file "$(basename "$plan_file")" \
    --arg project "$project_id" \
    --arg configuration "$configuration" \
    --arg operator "$operator" \
    --arg head "$head_sha" \
    --arg source "$source_sha" \
    --arg context "$context_sha" \
    --arg plan "$plan_sha" \
    --argjson now "$now" \
    --argjson max_age "$max_age_seconds" '
      (keys | sort) == ([
        "contextSha256",
        "createdAtEpoch",
        "expiresAtEpoch",
        "gcloudConfiguration",
        "headSha",
        "operator",
        "planFile",
        "planSha256",
        "projectId",
        "schemaVersion",
        "sourceSha256",
        "stack"
      ] | sort)
      and (.schemaVersion == 1)
      and (.stack == $stack)
      and (.planFile == $plan_file)
      and (.projectId == $project)
      and (.gcloudConfiguration == $configuration)
      and (.operator == $operator)
      and (.headSha == $head)
      and (.sourceSha256 == $source)
      and (.contextSha256 == $context)
      and (.planSha256 == $plan)
      and ((.createdAtEpoch | type) == "number")
      and ((.expiresAtEpoch | type) == "number")
      and (.createdAtEpoch <= $now)
      and ((.expiresAtEpoch - .createdAtEpoch) == $max_age)
      and (($now - .createdAtEpoch) <= $max_age)
      and ($now <= .expiresAtEpoch)
    ' "$metadata_file" >/dev/null || {
    printf '%s reviewed plan metadata is stale or does not match the current project, operator, source, context, or plan hash. Re-plan and review it again.\n' \
      "$stack_dir" >&2
    return 1
  }
}

saved_plan_contract_self_test() {
  local runtime_dir
  runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/saved-plan-contract.XXXXXX")"
  SAVED_PLAN_SELF_TEST_RUNTIME_DIR="$runtime_dir"
  trap 'rm -rf -- "$SAVED_PLAN_SELF_TEST_RUNTIME_DIR"' EXIT

  export PROJECT_ID="saved-plan-test-project"
  export BILLING_ACCOUNT_ID="000000-000000-000000"
  export GCLOUD_CONFIGURATION="saved-plan-test"
  export DOMAIN_NAME="example.test"
  export ENABLE_BINARY_AUTHORIZATION=0
  export ENABLE_CLOUD_ARMOR=0

  expect_accept() {
    local label="$1"
    shift
    "$@" || {
      printf 'FAIL: expected acceptance: %s\n' "$label" >&2
      return 1
    }
  }

  expect_reject() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      printf 'FAIL: expected rejection: %s\n' "$label" >&2
      return 1
    fi
  }

  local fixture
  fixture="$runtime_dir/00.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"variables":{"project_id":{"value":"saved-plan-test-project"},"billing_account_id":{"value":"000000-000000-000000"},"domain_name":{"value":"example.test"},"enable_binary_authorization":{"value":"false"}},"configuration":{"root_module":{"variables":{"billing_account_id":{"sensitive":true}}}},"resource_changes":[{"address":"google_project_service.required[\"logging.googleapis.com\"]","mode":"managed","type":"google_project_service","change":{"actions":["create"],"after":{"project":"saved-plan-test-project","service":"logging.googleapis.com","disable_dependent_services":false,"disable_on_destroy":false}}},{"address":"google_billing_budget.safety","mode":"managed","type":"google_billing_budget","change":{"actions":["create"],"after":{"billing_account":"000000-000000-000000","display_name":"Schwab Assessment - 30 USD Safety Budget","budget_filter":[{"calendar_period":"MONTH"}],"amount":[{"specified_amount":[{"currency_code":"USD","units":"30"}]}],"threshold_rules":[{"spend_basis":"CURRENT_SPEND","threshold_percent":0.5},{"spend_basis":"CURRENT_SPEND","threshold_percent":0.8},{"spend_basis":"CURRENT_SPEND","threshold_percent":0.9},{"spend_basis":"CURRENT_SPEND","threshold_percent":1}]}}},{"address":"google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity","mode":"managed","type":"google_cloud_quotas_quota_preference","change":{"actions":["create"],"after":{"parent":"projects/saved-plan-test-project","name":"compute-cpus-all-regions-96","service":"compute.googleapis.com","quota_id":"CPUS-ALL-REGIONS-per-project","quota_config":[{"preferred_value":"96"}]}}}],"output_changes":{"enabled_services":{"actions":["update"]},"budget_name":{"actions":["create"]},"gke_all_regions_cpu_quota":{"actions":["create"]}}}' >"$fixture"
  expect_accept '00-bootstrap fresh API create' \
    saved_plan_validate_json infra/00-bootstrap "$fixture"
  jq '(.resource_changes[0].change.actions) = ["no-op"]
    | (.resource_changes[0].change.after.disable_dependent_services) = null
    | (.resource_changes[0].change.after.disable_on_destroy) = null' \
    "$fixture" >"$runtime_dir/00-imported-service.json"
  expect_accept '00-bootstrap imported no-op service provider defaults' \
    saved_plan_validate_json infra/00-bootstrap \
      "$runtime_dir/00-imported-service.json"
  jq '(.resource_changes[0].change.actions) = ["create"]' \
    "$runtime_dir/00-imported-service.json" \
    >"$runtime_dir/00-create-null-service-flags.json"
  expect_reject '00-bootstrap new service with unknown destroy posture' \
    saved_plan_validate_json infra/00-bootstrap \
      "$runtime_dir/00-create-null-service-flags.json"

  fixture="$runtime_dir/10.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"variables":{"project_id":{"value":"saved-plan-test-project"},"billing_account_id":{"value":"000000-000000-000000"},"gcloud_configuration":{"value":"saved-plan-test"},"domain_name":{"value":"example.test"},"enable_binary_authorization":{"value":"false"}},"configuration":{"root_module":{"variables":{"billing_account_id":{"sensitive":true}}}},"resource_changes":[{"address":"google_service_account.app_b_telemetry","mode":"managed","type":"google_service_account","change":{"actions":["create"],"after":{"project":"saved-plan-test-project","account_id":"currency-app-b-telemetry"}}}],"output_changes":{"app_b_telemetry_service_account_email":{"actions":["update"]}}}' >"$fixture"
  expect_accept '10-global approved identity create' \
    saved_plan_validate_json infra/10-global "$fixture"

  fixture="$runtime_dir/10-computed-iam-member.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"variables":{"project_id":{"value":"saved-plan-test-project"},"billing_account_id":{"value":"000000-000000-000000"},"gcloud_configuration":{"value":"saved-plan-test"},"domain_name":{"value":"example.test"},"enable_binary_authorization":{"value":"false"}},"configuration":{"root_module":{"variables":{"billing_account_id":{"sensitive":true}}}},"resource_changes":[{"address":"google_project_iam_member.app_b_telemetry[\"roles/telemetry.tracesWriter\"]","mode":"managed","type":"google_project_iam_member","change":{"actions":["create"],"after":{"project":"saved-plan-test-project","role":"roles/telemetry.tracesWriter","member":null},"after_unknown":{"member":true}}}],"output_changes":{}}' >"$fixture"
  expect_accept '10-global fresh computed IAM member' \
    saved_plan_validate_json infra/10-global "$fixture"
  jq '.resource_changes[0].change.actions = ["update"]' "$fixture" \
    >"$runtime_dir/10-computed-iam-update.json"
  expect_reject '10-global computed IAM member outside create' \
    saved_plan_validate_json infra/10-global "$runtime_dir/10-computed-iam-update.json"

  fixture="$runtime_dir/30.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":false,"variables":{"project_id":{"value":"saved-plan-test-project"},"enable_cloud_armor":{"value":"false"}},"resource_changes":[],"output_changes":{"tls_enabled":{"actions":["no-op"],"after":true},"public_endpoint":{"actions":["no-op"],"after":"https://example.test"},"global_ipv4_address":{"actions":["no-op"],"after":"192.0.2.1"}}}' >"$fixture"
  expect_accept '30-lb converged HTTPS posture' \
    saved_plan_validate_json infra/30-lb "$fixture"

  fixture="$runtime_dir/delete.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"resource_changes":[{"address":"google_project_service.required","type":"google_project_service","change":{"actions":["delete"]}}],"output_changes":{}}' >"$fixture"
  expect_reject 'delete action' \
    saved_plan_validate_json infra/00-bootstrap "$fixture"

  fixture="$runtime_dir/replace.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"resource_changes":[{"address":"google_compute_subnetwork.regional","type":"google_compute_subnetwork","change":{"actions":["delete","create"]}}],"output_changes":{}}' >"$fixture"
  expect_reject 'replacement action' \
    saved_plan_validate_json infra/10-global "$fixture"

  fixture="$runtime_dir/arbitrary-iam.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"variables":{"project_id":{"value":"saved-plan-test-project"},"gcloud_configuration":{"value":"saved-plan-test"},"domain_name":{"value":"example.test"},"enable_binary_authorization":{"value":"false"}},"resource_changes":[{"address":"google_project_iam_member.owner","mode":"managed","type":"google_project_iam_member","change":{"actions":["create"],"after":{"role":"roles/owner","member":"user:attacker@example.test"}}}],"output_changes":{}}' >"$fixture"
  expect_reject 'unknown privileged IAM grant' \
    saved_plan_validate_json infra/10-global "$fixture"

  fixture="$runtime_dir/arbitrary-network.json"
  printf '%s\n' '{"complete":true,"errored":false,"applyable":true,"variables":{"project_id":{"value":"saved-plan-test-project"},"gcloud_configuration":{"value":"saved-plan-test"},"domain_name":{"value":"example.test"},"enable_binary_authorization":{"value":"false"}},"resource_changes":[{"address":"google_compute_firewall.public_admin","mode":"managed","type":"google_compute_firewall","change":{"actions":["create"],"after":{"source_ranges":["0.0.0.0/0"],"allow":[{"protocol":"tcp","ports":["22"]}]}}}],"output_changes":{}}' >"$fixture"
  expect_reject 'unknown public network rule' \
    saved_plan_validate_json infra/10-global "$fixture"

  local plan_file="$runtime_dir/reviewed-apply.tfplan"
  local metadata_file="$runtime_dir/reviewed-apply.meta.json"
  printf 'immutable test plan\n' >"$plan_file"
  saved_plan_write_metadata \
    infra/30-lb "$plan_file" "$metadata_file" project config operator \
    0123456789012345678901234567890123456789 source-hash context-hash 1000
  expect_accept 'matching metadata' saved_plan_verify_metadata \
    infra/30-lb "$plan_file" "$metadata_file" project config operator \
    0123456789012345678901234567890123456789 source-hash context-hash 1001
  expect_reject 'context mismatch' saved_plan_verify_metadata \
    infra/30-lb "$plan_file" "$metadata_file" project config operator \
    0123456789012345678901234567890123456789 source-hash other-context 1001
  expect_reject 'source mismatch' saved_plan_verify_metadata \
    infra/30-lb "$plan_file" "$metadata_file" project config operator \
    0123456789012345678901234567890123456789 other-source context-hash 1001
  expect_reject 'stale metadata' saved_plan_verify_metadata \
    infra/30-lb "$plan_file" "$metadata_file" project config operator \
    0123456789012345678901234567890123456789 source-hash context-hash 2801
  printf 'mutated test plan\n' >"$plan_file"
  expect_reject 'plan hash mismatch' saved_plan_verify_metadata \
    infra/30-lb "$plan_file" "$metadata_file" project config operator \
    0123456789012345678901234567890123456789 source-hash context-hash 1001

  printf 'Saved-plan contract self-test passed.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  if [[ "${1:-}" != "--self-test" || $# -ne 1 ]]; then
    printf 'Usage: %s --self-test\n' "$0" >&2
    exit 2
  fi
  for required_command in find jq mktemp sha256sum sort; do
    command -v "$required_command" >/dev/null 2>&1 || {
      printf '%s is required.\n' "$required_command" >&2
      exit 1
    }
  done
  saved_plan_contract_self_test
fi

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=terraform-saved-plan-contract.sh
source "$repo_root/scripts/terraform-saved-plan-contract.sh"

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s STACK_DIR plan|apply|destroy\n' "$0" >&2
  exit 2
fi

stack_dir="$1"
action="$2"
expected_account="satish.cse7@gmail.com"
terraform_timeout="${TERRAFORM_TIMEOUT:-50m}"

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${BILLING_ACCOUNT_ID:?BILLING_ACCOUNT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"

enable_cloud_armor="${ENABLE_CLOUD_ARMOR:-0}"
enable_binary_authorization="${ENABLE_BINARY_AUTHORIZATION:-0}"
allow_central_cluster_replacement="${ALLOW_CENTRAL_CLUSTER_REPLACEMENT:-0}"
for feature_flag in enable_cloud_armor enable_binary_authorization allow_central_cluster_replacement; do
  feature_value="${!feature_flag}"
  [[ "$feature_value" == "0" || "$feature_value" == "1" ]] || {
    printf '%s must be 0 or 1.\n' "${feature_flag^^}" >&2
    exit 2
  }
done

case "$action" in
  plan|apply|destroy) ;;
  *)
    printf 'Unsupported Terraform action: %s\n' "$action" >&2
    exit 2
    ;;
esac

[[ -d "$stack_dir" ]] || {
  printf 'Terraform stack not found: %s\n' "$stack_dir" >&2
  exit 1
}

case "$stack_dir" in
  infra/00-bootstrap|infra/10-global|infra/20-cluster|infra/30-lb) ;;
  *)
    printf 'Terraform stack is not approved by this wrapper: %s\n' "$stack_dir" >&2
    exit 2
    ;;
esac

for required_command in gcloud git jq sha256sum terraform timeout; do
  command -v "$required_command" >/dev/null 2>&1 || {
    printf '%s is required.\n' "$required_command" >&2
    exit 1
  }
done

for override_name in \
  CLOUDSDK_ACTIVE_CONFIG_NAME CLOUDSDK_CONFIG \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  CLOUDSDK_CORE_ACCOUNT CLOUDSDK_CORE_PROJECT \
  GOOGLE_ACCESS_TOKEN GOOGLE_APPLICATION_CREDENTIALS \
  GOOGLE_BACKEND_CREDENTIALS GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_BILLING_PROJECT GOOGLE_CLOUD_KEYFILE_JSON \
  GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_QUOTA_PROJECT GOOGLE_CREDENTIALS \
  GOOGLE_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_IMPERSONATE_SERVICE_ACCOUNT_DELEGATES GOOGLE_OAUTH_ACCESS_TOKEN \
  GOOGLE_PROJECT GOOGLE_REGION GOOGLE_ZONE \
  TF_CLI_ARGS TF_CLI_CONFIG_FILE TF_DATA_DIR TF_WORKSPACE; do
  [[ -z "${!override_name:-}" ]] || {
    printf '%s must be unset before Terraform authentication.\n' \
      "$override_name" >&2
    exit 1
  }
done

while IFS='=' read -r terraform_override terraform_override_value; do
  [[ -z "$terraform_override" || -z "$terraform_override_value" ]] && continue
  printf '%s must be unset before Terraform initialization.\n' \
    "$terraform_override" >&2
  exit 1
done < <(
  env | LC_ALL=C grep -E \
    '^(TF_CLI_ARGS_[A-Za-z0-9_]*|TFC_GCP_[A-Za-z0-9_]*|TFC_DEFAULT_GCP_[A-Za-z0-9_]*)=' \
    || true
)

for auth_property in \
  auth/access_token_file auth/credential_file_override \
  auth/impersonate_service_account; do
  auth_value="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      config get-value "$auth_property" 2>/dev/null
  )"
  [[ -z "$auth_value" || "$auth_value" == "(unset)" ]] || {
    printf '%s must be unset in gcloud configuration %s.\n' \
      "$auth_property" "$GCLOUD_CONFIGURATION" >&2
    exit 1
  }
done

if [[ "$action" == "apply" && "$stack_dir" == "infra/30-lb" ]]; then
  : "${APP_A_IMAGE_TAG:?APP_A_IMAGE_TAG is required before the 30-lb apply}"
  : "${APP_B_IMAGE_TAG:?APP_B_IMAGE_TAG is required before the 30-lb apply}"
  [[ "$APP_A_IMAGE_TAG" =~ ^[0-9a-f]{40}$ \
    && "$APP_B_IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'APP_A_IMAGE_TAG and APP_B_IMAGE_TAG must be full lowercase 40-character Git SHAs.\n' >&2
    exit 2
  }
  git cat-file -e "$APP_A_IMAGE_TAG^{commit}" 2>/dev/null \
    && git cat-file -e "$APP_B_IMAGE_TAG^{commit}" 2>/dev/null || {
    printf 'Both 30-lb release SHAs must be commits in this repository.\n' >&2
    exit 2
  }
fi

if [[ "$stack_dir" == "infra/20-cluster" ]]; then
  : "${ADMIN_CIDR:?ADMIN_CIDR is required for infra/20-cluster}"

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

  if [[ "$admin_ip" == "0.0.0.0" ]]; then
    printf 'ADMIN_CIDR must not authorize 0.0.0.0/32.\n' >&2
    exit 1
  fi
fi

active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
if [[ "$active_account" != "$expected_account" ]]; then
  printf 'Expected gcloud account %s, found %s.\n' "$expected_account" "${active_account:-<none>}" >&2
  exit 1
fi

configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
if [[ "$configured_project" != "$PROJECT_ID" ]]; then
  printf 'Expected gcloud project %s, found %s.\n' "$PROJECT_ID" "${configured_project:-<none>}" >&2
  exit 1
fi

SAVED_PLAN_OPERATOR="$active_account"
export SAVED_PLAN_OPERATOR

TF_VAR_project_id="$PROJECT_ID"
TF_VAR_billing_account_id="$BILLING_ACCOUNT_ID"
TF_VAR_gcloud_configuration="$GCLOUD_CONFIGURATION"
TF_VAR_domain_name="${DOMAIN_NAME:-}"
TF_VAR_admin_cidr="${ADMIN_CIDR:-}"
TF_VAR_enable_cloud_armor=false
TF_VAR_enable_binary_authorization=false
[[ "$enable_cloud_armor" == "1" ]] && TF_VAR_enable_cloud_armor=true
[[ "$enable_binary_authorization" == "1" ]] && TF_VAR_enable_binary_authorization=true
export TF_VAR_project_id TF_VAR_billing_account_id TF_VAR_gcloud_configuration
export TF_VAR_domain_name TF_VAR_admin_cidr
export TF_VAR_enable_cloud_armor TF_VAR_enable_binary_authorization
owned_cluster_plan=""
owned_reviewed_plan_temp=""
owned_reviewed_metadata_temp=""
owned_reviewed_json_temp=""
cleanup() {
  if [[ -n "$owned_cluster_plan" ]]; then
    rm -f -- "$owned_cluster_plan"
  fi
  if [[ -n "$owned_reviewed_plan_temp" ]]; then
    rm -f -- "$owned_reviewed_plan_temp"
  fi
  if [[ -n "$owned_reviewed_metadata_temp" ]]; then
    rm -f -- "$owned_reviewed_metadata_temp"
  fi
  if [[ -n "$owned_reviewed_json_temp" ]]; then
    rm -f -- "$owned_reviewed_json_temp"
  fi
  unset GOOGLE_OAUTH_ACCESS_TOKEN TF_VAR_project_id TF_VAR_billing_account_id
  unset TF_VAR_gcloud_configuration TF_VAR_domain_name TF_VAR_admin_cidr
  unset TF_VAR_enable_cloud_armor TF_VAR_enable_binary_authorization
  unset SAVED_PLAN_OPERATOR
}
trap cleanup EXIT

run_terraform() {
  timeout --foreground --signal=INT --kill-after=15s \
    "$terraform_timeout" terraform "$@"
}

is_reviewed_stack=0
case "$stack_dir" in
  infra/00-bootstrap|infra/10-global|infra/30-lb) is_reviewed_stack=1 ;;
esac

if [[ "$is_reviewed_stack" == "1" \
  && ( "$action" == "plan" || "$action" == "apply" ) ]]; then
  git_status="$(git status --porcelain --untracked-files=all)"
  [[ -z "$git_status" ]] || {
    printf '%s %s requires a completely clean Git worktree so the reviewed plan is bound to committed source.\n' \
      "$stack_dir" "$action" >&2
    exit 1
  }
fi

run_terraform -chdir="$stack_dir" init -input=false

mint_terraform_token() {
  # Mint the non-refreshable user token immediately before the bounded cloud
  # operation. A timed-out operation is safe to rerun from state.
  GOOGLE_OAUTH_ACCESS_TOKEN="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" auth print-access-token
  )"
  export GOOGLE_OAUTH_ACCESS_TOKEN
}

terraform_workspace="$(run_terraform -chdir="$stack_dir" workspace show)"
reviewed_plan_rel=".terraform/reviewed-apply.tfplan"
reviewed_metadata_rel=".terraform/reviewed-apply.meta.json"
reviewed_plan="$stack_dir/$reviewed_plan_rel"
reviewed_metadata="$stack_dir/$reviewed_metadata_rel"

if [[ "$action" == "destroy" && "$is_reviewed_stack" == "1" ]]; then
  rm -f -- "$reviewed_metadata" "$reviewed_plan"
fi

if [[ "$action" == "plan" ]]; then
  if [[ "$is_reviewed_stack" == "0" ]]; then
    mint_terraform_token
    run_terraform -chdir="$stack_dir" plan -input=false
    exit 0
  fi

  git check-ignore --quiet -- "$reviewed_plan" \
    && git check-ignore --quiet -- "$reviewed_metadata" || {
    printf 'Reviewed Terraform plans and metadata must remain ignored.\n' >&2
    exit 1
  }

  # Beginning a new review invalidates any older pair. A failed refresh can
  # therefore never leave a previously reviewed plan looking current.
  rm -f -- "$reviewed_metadata" "$reviewed_plan"
  reviewed_plan_temp_rel=".terraform/reviewed-apply.$$.tfplan"
  owned_reviewed_plan_temp="$stack_dir/$reviewed_plan_temp_rel"
  owned_reviewed_metadata_temp="$stack_dir/.terraform/reviewed-apply.$$.meta.json"
  owned_reviewed_json_temp="$stack_dir/.terraform/reviewed-apply.$$.json"

  mint_terraform_token
  run_terraform -chdir="$stack_dir" plan -input=false \
    -out="$reviewed_plan_temp_rel"
  run_terraform -chdir="$stack_dir" show -json "$reviewed_plan_temp_rel" \
    >"$owned_reviewed_json_temp"
  saved_plan_validate_json "$stack_dir" "$owned_reviewed_json_temp"

  # This view is generated from the exact binary that will be eligible for
  # apply, rather than from a second plan operation.
  run_terraform -chdir="$stack_dir" show -no-color "$reviewed_plan_temp_rel"
  mv -f -- "$owned_reviewed_plan_temp" "$reviewed_plan"
  owned_reviewed_plan_temp=""

  head_sha="$(git rev-parse --verify 'HEAD^{commit}')"
  source_sha="$(saved_plan_source_fingerprint "$stack_dir")"
  context_sha="$(
    saved_plan_context_fingerprint "$stack_dir" "$terraform_workspace"
  )"
  saved_plan_write_metadata \
    "$stack_dir" "$reviewed_plan" "$owned_reviewed_metadata_temp" \
    "$PROJECT_ID" "$GCLOUD_CONFIGURATION" "$active_account" "$head_sha" \
    "$source_sha" "$context_sha"
  mv -f -- "$owned_reviewed_metadata_temp" "$reviewed_metadata"
  owned_reviewed_metadata_temp=""

  printf 'Saved the exact reviewed plan and 30-minute metadata contract:\n'
  printf '  %s\n  %s\n' "$reviewed_plan" "$reviewed_metadata"
  exit 0
fi

approve_args=()
if [[ "${TF_AUTO_APPROVE:-0}" == "1" ]]; then
  approve_args=(-auto-approve)
fi

if [[ "$action" == "apply" && "$is_reviewed_stack" == "1" ]]; then
  [[ "${TF_AUTO_APPROVE:-0}" == "1" ]] || {
    printf '%s apply requires TF_AUTO_APPROVE=1 after reviewing its saved plan.\n' \
      "$stack_dir" >&2
    exit 2
  }

  head_sha="$(git rev-parse --verify 'HEAD^{commit}')"
  source_sha="$(saved_plan_source_fingerprint "$stack_dir")"
  context_sha="$(
    saved_plan_context_fingerprint "$stack_dir" "$terraform_workspace"
  )"
  saved_plan_verify_metadata \
    "$stack_dir" "$reviewed_plan" "$reviewed_metadata" \
    "$PROJECT_ID" "$GCLOUD_CONFIGURATION" "$active_account" "$head_sha" \
    "$source_sha" "$context_sha"

  owned_reviewed_json_temp="$stack_dir/.terraform/reviewed-apply.$$.json"
  run_terraform -chdir="$stack_dir" show -json "$reviewed_plan_rel" \
    >"$owned_reviewed_json_temp"
  saved_plan_validate_json "$stack_dir" "$owned_reviewed_json_temp"

  consumed_plan_rel=".terraform/reviewed-apply.applying.$$.tfplan"
  owned_reviewed_plan_temp="$stack_dir/$consumed_plan_rel"
  mv -- "$reviewed_plan" "$owned_reviewed_plan_temp"
  rm -f -- "$reviewed_metadata"

  mint_terraform_token
  run_terraform -chdir="$stack_dir" apply -input=false "$consumed_plan_rel"
  rm -f -- "$owned_reviewed_plan_temp"
  owned_reviewed_plan_temp=""
elif [[ "$action" == "apply" && "$stack_dir" == "infra/20-cluster" ]]; then
  mint_terraform_token

  [[ "${TF_AUTO_APPROVE:-0}" == "1" ]] || {
    printf 'Cluster apply requires TF_AUTO_APPROVE=1 after reviewing the saved plan.\n' >&2
    exit 2
  }
  if [[ "$allow_central_cluster_replacement" == "1" \
    && "$enable_binary_authorization" != "0" ]]; then
    printf 'Central cluster replacement requires Binary Authorization to remain disabled.\n' >&2
    exit 2
  fi
  gated_plan=".terraform/cluster-apply-gate.$$.tfplan"
  owned_cluster_plan="$stack_dir/$gated_plan"
  rm -f -- "$owned_cluster_plan"
  cluster_plan_args=()
  if [[ "$allow_central_cluster_replacement" == "1" ]]; then
    cluster_plan_args=(
      '-replace=module.autopilot_cluster["us-central1"].google_container_cluster.this'
    )
  fi
  run_terraform -chdir="$stack_dir" plan -input=false \
    -out="$gated_plan" "${cluster_plan_args[@]}"
  gated_plan_json="$(run_terraform -chdir="$stack_dir" show -json "$gated_plan")"
  jq -e --arg central 'module.autopilot_cluster["us-central1"].google_container_cluster.this' \
    --arg east 'module.autopilot_cluster["us-east4"].google_container_cluster.this' \
    --arg allow_replacement "$allow_central_cluster_replacement" \
    --arg project "$PROJECT_ID" \
    --arg admin_cidr "$ADMIN_CIDR" \
    --arg node_sa "risk-gke-usc1-nodes@$PROJECT_ID.iam.gserviceaccount.com" '
    .resource_changes as $changes
    | ($changes | map(select(.address == $central)) | first) as $central_change
    | (($central_change.change.before.node_locations // []) | sort) as $central_before
    | (($central_change.change.after.node_locations // []) | sort) as $central_after
    | (
        ($central_change.change.before != null)
        and ($central_change.change.after != null)
        and ($central_before != $central_after)
      ) as $central_locations_change
    | (.complete == true)
      and (.errored == false)
      and ([$changes[] | select(.address == $central)] | length == 1)
      and ([$changes[] | select(.address == $east)] | length == 1)
      and all($changes[]?;
        (
          (
            .address == "terraform_data.global_contract"
            and (
              (.change.actions == ["create"])
              or (.change.actions == ["no-op"])
            )
          )
          or (
            ((.address == $central) or (.address == $east))
            and (
              (
                ($allow_replacement == "1")
                and (.address == $central)
                and (.change.actions == ["delete", "create"])
              )
              or (.change.actions == ["create"])
              or (.change.actions == ["update"])
              or (.change.actions == ["no-op"])
            )
          )
        )
      )
      and (
        if ($allow_replacement == "1") then
          ($central_change.change.after) as $after
          |
          ([$changes[] | select(.change.actions != ["no-op"])] | length == 1)
          and ($central_change.change.actions == ["delete", "create"])
          and (
            ($central_before == ["us-central1-a", "us-central1-b", "us-central1-c"])
          )
          and ($central_after == ["us-central1-b", "us-central1-c", "us-central1-f"])
          and (($central_change.change.before.name // "") == "gke-risk-usc1")
          and (($central_change.change.after.name // "") == "gke-risk-usc1")
          and (($central_change.change.after.location // "") == "us-central1")
          and (($central_change.change.after.enable_autopilot // false) == true)
          and ($central_change.change.after.deletion_protection == false)
          and ($after.project == $project)
          and ($after.network | endswith("/projects/\($project)/global/networks/risk-vpc"))
          and ($after.subnetwork | endswith("/projects/\($project)/regions/us-central1/subnetworks/risk-usc1"))
          and ($after.networking_mode == "VPC_NATIVE")
          and ($after.datapath_provider == "ADVANCED_DATAPATH")
          and ($after.release_channel == [{"channel":"REGULAR"}])
          and ($after.resource_labels == {
            "managed_by":"terraform",
            "region":"us-central1",
            "workload":"risk-assessment"
          })
          and ($after.workload_identity_config == [{"workload_pool":"\($project).svc.id.goog"}])
          and (
            $after.ip_allocation_policy == [{
              "additional_ip_ranges_config":[],
              "additional_pod_ranges_config":[],
              "cluster_secondary_range_name":"risk-usc1-pods",
              "services_secondary_range_name":"risk-usc1-services",
              "stack_type":"IPV4"
            }]
          )
          and (($after.private_cluster_config | length) == 1)
          and ($after.private_cluster_config[0].enable_private_nodes == true)
          and (($after.private_cluster_config[0].enable_private_endpoint // false) == false)
          and ($after.private_cluster_config[0].master_ipv4_cidr_block == "172.16.0.0/28")
          and ($after.private_cluster_config[0].master_global_access_config == [{"enabled":false}])
          and (
            $after.master_authorized_networks_config == [{
              "cidr_blocks":[{"cidr_block":$admin_cidr,"display_name":"assessment-admin"}],
              "gcp_public_cidrs_access_enabled":false
            }]
          )
          and ($after.cluster_autoscaling[0].auto_provisioning_defaults[0].service_account == $node_sa)
          and (($after.logging_config[0].enable_components | sort) == [
            "APISERVER",
            "CONTROLLER_MANAGER",
            "KCP_HPA",
            "SCHEDULER",
            "SYSTEM_COMPONENTS",
            "WORKLOADS"
          ])
          and ($after.monitoring_config == [{"enable_components":["SYSTEM_COMPONENTS"]}])
          and (($after.binary_authorization // []) == [])
          and (($changes | map(select(.address == $east)) | first).change.actions == ["no-op"])
        else
          all($changes[]?; ((.change.actions | index("delete")) == null))
          and ($central_locations_change | not)
          and all([$central_change, ($changes
            | map(select(.address == $east)) | first)][];
            if .change.actions == ["update"] then
              ((.change.before.logging_config[0].enable_components | sort)
                == ["SYSTEM_COMPONENTS", "WORKLOADS"])
              and ((.change.after.logging_config[0].enable_components | sort) == [
                "APISERVER",
                "CONTROLLER_MANAGER",
                "KCP_HPA",
                "SCHEDULER",
                "SYSTEM_COMPONENTS",
                "WORKLOADS"
              ])
              and (.change.before
                | del(.logging_config)
                | del(.resource_labels["goog-terraform-provisioned"])
                | del(.terraform_labels["goog-terraform-provisioned"]))
                == (.change.after
                  | del(.logging_config)
                  | del(.resource_labels["goog-terraform-provisioned"])
                  | del(.terraform_labels["goog-terraform-provisioned"]))
            else
              .change.actions == ["no-op"]
            end)
        end
      )
  ' <<<"$gated_plan_json" >/dev/null || {
    printf 'Cluster apply refused: the saved plan changes an unknown resource or violates the exact guarded cluster contract.\n' >&2
    exit 1
  }
  changed_resource_count="$(
    jq '[.resource_changes[]? | select(.change.actions != ["no-op"])] | length' \
      <<<"$gated_plan_json"
  )"
  changed_output_count="$(
    jq '[.output_changes[]? | select(.actions != ["no-op"])] | length' \
      <<<"$gated_plan_json"
  )"
  if [[ "$changed_resource_count" == "0" && "$changed_output_count" == "0" ]]; then
    printf 'Verified the cluster stack is already converged; there is no saved-plan change to apply.\n'
  else
    jq -e '.applyable == true' <<<"$gated_plan_json" >/dev/null || {
      printf 'Cluster apply refused: Terraform did not produce an applyable saved plan.\n' >&2
      exit 1
    }
    if [[ "$changed_resource_count" == "0" ]]; then
      printf 'Verified the saved plan changes only Terraform output state; live resources are unchanged.\n'
    elif [[ "$allow_central_cluster_replacement" == "1" ]]; then
      printf 'Verified the saved plan replaces only the central cluster from a/b/c to b/c/f.\n'
    else
      printf 'Verified the saved cluster plan contains no replacement or destroy action.\n'
    fi
    run_terraform -chdir="$stack_dir" apply -input=false "$gated_plan"
  fi
else
  mint_terraform_token
  run_terraform -chdir="$stack_dir" "$action" -input=false "${approve_args[@]}"
fi

# Terraform uses a short-lived OAuth token so its cloud operation is bounded
# and independent of application verification. Never let that bearer token
# leak into the post-apply gcloud/kubectl gates; those gates authenticate with
# their explicitly configured user or impersonated service-account identities.
unset GOOGLE_OAUTH_ACCESS_TOKEN

if [[ "$action" == "apply" && "$stack_dir" == "infra/00-bootstrap" ]]; then
  project_number="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" projects describe "$PROJECT_ID" \
      --format='value(projectNumber)'
  )"
  [[ "$project_number" =~ ^[0-9]+$ ]] || {
    printf 'Could not resolve the numeric project ID for budget verification.\n' >&2
    exit 1
  }

  budgets_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" billing budgets list \
      --billing-account="$BILLING_ACCOUNT_ID" \
      --format=json
  )"

  jq -e \
    --arg display_name 'Schwab Assessment - 30 USD Safety Budget' \
    --arg project "projects/$project_number" \
    '
      [.[] | select(.displayName == $display_name)] as $matches
      | (($matches | length) == 1)
        and ($matches[0].budgetFilter.projects == [$project])
        and ($matches[0].amount.specifiedAmount.currencyCode == "USD")
        and (($matches[0].amount.specifiedAmount.units | tonumber) == 30)
        and (($matches[0].amount.specifiedAmount.nanos // 0) == 0)
        and (
          [$matches[0].thresholdRules[]
            | select(.spendBasis == "CURRENT_SPEND")
            | .thresholdPercent]
          | sort
          == [0.5, 0.8, 0.9, 1]
        )
    ' <<<"$budgets_json" >/dev/null || {
      printf 'The project budget does not match the frozen 30 USD contract.\n' >&2
      exit 1
    }

  printf 'Verified project-scoped 30 USD budget and four current-spend thresholds.\n'

  enabled_quota_api="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      services list --enabled \
      --filter='config.name=cloudquotas.googleapis.com' \
      --format='value(config.name)'
  )"
  [[ "$enabled_quota_api" == "cloudquotas.googleapis.com" ]] || {
    printf 'Cloud Quotas API is not enabled.\n' >&2
    exit 1
  }

  quota_preference_json="$(
    gcloud beta quotas preferences describe compute-cpus-all-regions-96 \
      --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" --format=json
  )"
  jq -e --arg project "$PROJECT_ID" '
    .name == ("projects/" + $project + "/locations/global/quotaPreferences/compute-cpus-all-regions-96") and
    .service == "compute.googleapis.com" and
    .quotaId == "CPUS-ALL-REGIONS-per-project" and
    (.quotaConfig.preferredValue | tonumber) == 96 and
    (.quotaConfig.grantedValue | tonumber) >= 96 and
    ((.reconciling // false) == false)
  ' <<<"$quota_preference_json" >/dev/null || {
    printf 'The all-regions CPU quota preference is not approved at the frozen 96-vCPU ceiling.\n' >&2
    exit 1
  }

  compute_quotas_json="$(
    gcloud --configuration="$GCLOUD_CONFIGURATION" \
      --account="$expected_account" --project="$PROJECT_ID" \
      compute project-info describe --format=json
  )"
  jq -e '
    [.quotas[] | select(.metric == "CPUS_ALL_REGIONS")] as $matches |
    ($matches | length) == 1 and ($matches[0].limit | tonumber) >= 96
  ' <<<"$compute_quotas_json" >/dev/null || {
    printf 'Compute does not report the approved all-regions CPU limit of at least 96.\n' >&2
    exit 1
  }

  printf 'Verified approved 96-vCPU all-regions quota preference; quota is a ceiling, not allocated capacity.\n'

  for region in us-central1 us-east4; do
    preference_name="compute-ssd-total-gb-${region}"
    quota_preference_json="$(
      gcloud beta quotas preferences describe "$preference_name" \
        --configuration="$GCLOUD_CONFIGURATION" \
        --account="$expected_account" --project="$PROJECT_ID" --format=json
    )"
    jq -e \
      --arg project "$PROJECT_ID" \
      --arg name "$preference_name" \
      --arg region "$region" '
      .name == ("projects/" + $project + "/locations/global/quotaPreferences/" + $name) and
      .service == "compute.googleapis.com" and
      .quotaId == "SSD-TOTAL-GB-per-project-region" and
      .dimensions == {region: $region} and
      (.quotaConfig.preferredValue | tonumber) == 900 and
      (.quotaConfig.grantedValue | tonumber) >= 900 and
      ((.reconciling // false) == false)
    ' <<<"$quota_preference_json" >/dev/null || {
      printf 'The %s regional SSD quota preference is not approved at the frozen 900-GB ceiling.\n' \
        "$region" >&2
      exit 1
    }

    regional_compute_quotas_json="$(
      gcloud --configuration="$GCLOUD_CONFIGURATION" \
        --account="$expected_account" --project="$PROJECT_ID" \
        compute regions describe "$region" --format=json
    )"
    jq -e '
      [.quotas[] | select(.metric == "SSD_TOTAL_GB")] as $matches |
      ($matches | length) == 1 and ($matches[0].limit | tonumber) >= 900
    ' <<<"$regional_compute_quotas_json" >/dev/null || {
      printf 'Compute does not report a regional SSD limit of at least 900 GB in %s.\n' \
        "$region" >&2
      exit 1
    }

    printf 'Verified approved 900-GB regional SSD quota preference and Compute limit in %s.\n' \
      "$region"
  done

  printf 'Regional SSD quota is a ceiling, not allocated storage; actual Autopilot disks remain billable.\n'
fi

if [[ "$action" == "apply" && "$stack_dir" == "infra/10-global" ]]; then
  bash ./scripts/verify-global.sh
fi

if [[ "$action" == "apply" && "$stack_dir" == "infra/20-cluster" ]]; then
  bash ./scripts/verify-clusters.sh
fi

if [[ "$action" == "apply" && "$stack_dir" == "infra/30-lb" ]]; then
  bash ./scripts/verify-deployment-gates.sh "$APP_A_IMAGE_TAG" "$APP_B_IMAGE_TAG"
fi

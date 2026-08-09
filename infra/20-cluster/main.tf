data "terraform_remote_state" "global" {
  backend = "local"

  config = {
    path = "${path.module}/../10-global/terraform.tfstate"
  }
}

resource "terraform_data" "global_contract" {
  input = data.terraform_remote_state.global.outputs.project_id

  lifecycle {
    precondition {
      condition     = data.terraform_remote_state.global.outputs.project_id == var.project_id
      error_message = "project_id does not match the project exported by 10-global."
    }

    precondition {
      condition     = data.terraform_remote_state.global.outputs.network_name == "risk-vpc"
      error_message = "10-global must export the frozen risk-vpc network."
    }

    precondition {
      condition = alltrue([
        for region, cell in local.cells :
        data.terraform_remote_state.global.outputs.subnetwork_names[region] == cell.subnet_name
      ])
      error_message = "10-global subnet names do not match the frozen regional contract."
    }

    precondition {
      condition = alltrue([
        for region, cell in local.cells :
        data.terraform_remote_state.global.outputs.secondary_ranges[region].pods == cell.pod_range_name &&
        data.terraform_remote_state.global.outputs.secondary_ranges[region].services == cell.service_range_name
      ])
      error_message = "10-global secondary range names do not match the frozen Pod and Service range contract."
    }

    precondition {
      condition = alltrue([
        for region, cell in local.cells :
        data.terraform_remote_state.global.outputs.node_service_account_emails[region] ==
        "${cell.node_account_id}@${var.project_id}.iam.gserviceaccount.com"
      ])
      error_message = "10-global node service accounts do not match the frozen regional identities."
    }
  }
}

module "autopilot_cluster" {
  for_each = local.cells
  source   = "./modules/autopilot-cluster"

  project_id                 = var.project_id
  name                       = each.value.cluster_name
  region                     = each.key
  node_locations             = each.value.node_locations
  network_self_link          = data.terraform_remote_state.global.outputs.network_self_link
  subnetwork_self_link       = data.terraform_remote_state.global.outputs.subnetwork_self_links[each.key]
  pod_range_name             = each.value.pod_range_name
  service_range_name         = each.value.service_range_name
  master_cidr                = each.value.master_cidr
  admin_cidr                 = trimspace(var.admin_cidr)
  node_service_account_email = data.terraform_remote_state.global.outputs.node_service_account_emails[each.key]
  labels                     = merge(local.labels, { region = each.key })

  depends_on = [terraform_data.global_contract]
}

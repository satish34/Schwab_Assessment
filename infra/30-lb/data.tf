data "terraform_remote_state" "global" {
  backend = "local"

  config = {
    path = "${path.module}/../10-global/terraform.tfstate"
  }
}

resource "terraform_data" "global_contract" {
  input = var.project_id

  lifecycle {
    precondition {
      condition     = try(local.global_outputs.project_id, "") == var.project_id
      error_message = "project_id does not match the project exported by 10-global."
    }

    precondition {
      condition = (
        try(local.global_outputs.network_name, "") == "risk-vpc" &&
        endswith(try(local.global_outputs.network_self_link, ""), "/networks/risk-vpc")
      )
      error_message = "10-global must export the frozen risk-vpc network."
    }

    precondition {
      condition     = try(local.global_outputs.global_address_name, "") == "risk-global-ip"
      error_message = "10-global must export the frozen risk-global-ip address."
    }

    precondition {
      condition = (
        can(cidrhost("${try(local.global_outputs.global_ipv4_address, "")}/32", 0)) &&
        !strcontains(try(local.global_outputs.global_ipv4_address, ""), ":")
      )
      error_message = "10-global must export a valid reserved global IPv4 address."
    }

    precondition {
      condition = alltrue([
        for region in ["us-central1", "us-east4"] :
        endswith(
          try(local.global_outputs.subnetwork_self_links[region], ""),
          "/subnetworks/${region == "us-central1" ? "risk-usc1" : "risk-use4"}"
        )
      ])
      error_message = "10-global subnet outputs do not match the frozen regional contract."
    }

    precondition {
      condition = (
        (local.certificate_map_id == "" && local.domain_name == "") ||
        (
          local.certificate_map_id != "" &&
          local.domain_name != "" &&
          endswith(local.certificate_map_id, "/certificateMaps/risk-cert-map") &&
          can(regex(
            "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$",
            local.domain_name
          ))
        )
      )
      error_message = "Trusted HTTPS requires paired domain_name and risk-cert-map outputs from 10-global."
    }
  }
}

data "google_compute_network_endpoint_group" "app_a" {
  for_each = local.negs

  project = var.project_id
  name    = each.value.name
  zone    = each.key

  lifecycle {
    precondition {
      condition = (
        try(local.global_outputs.project_id, "") == var.project_id &&
        try(local.global_outputs.network_name, "") == "risk-vpc"
      )
      error_message = "The 10-global project and network contract must pass before any NEG lookup."
    }

    postcondition {
      condition     = self.name == each.value.name
      error_message = "The NEG returned for ${each.key} does not have the frozen name."
    }

    postcondition {
      condition     = self.project == var.project_id
      error_message = "The NEG in ${each.key} is not in the dedicated project."
    }

    postcondition {
      condition     = self.network_endpoint_type == "GCE_VM_IP_PORT"
      error_message = "The NEG in ${each.key} must be a zonal GCE_VM_IP_PORT NEG."
    }

    postcondition {
      condition = (
        self.network == "risk-vpc" ||
        endswith(self.network, "/networks/risk-vpc")
      )
      error_message = "The NEG in ${each.key} is not attached to risk-vpc."
    }

    postcondition {
      condition = (
        self.subnetwork == (each.value.region == "us-central1" ? "risk-usc1" : "risk-use4") ||
        endswith(
          self.subnetwork,
          "/subnetworks/${each.value.region == "us-central1" ? "risk-usc1" : "risk-use4"}"
        )
      )
      error_message = "The NEG in ${each.key} is not attached to the frozen regional subnet."
    }
  }
}

resource "terraform_data" "neg_contract" {
  input = local.negs

  lifecycle {
    precondition {
      condition     = length(data.google_compute_network_endpoint_group.app_a) == 6
      error_message = "All six frozen zonal App A NEGs must exist before 30-lb is applied."
    }

    precondition {
      condition = alltrue([
        for region in ["us-central1", "us-east4"] :
        sum([
          for zone, neg in data.google_compute_network_endpoint_group.app_a : neg.size
          if local.negs[zone].region == region
        ]) >= 2
      ])
      error_message = "Each region must have at least two registered App A NEG endpoints before 30-lb is applied."
    }
  }
}

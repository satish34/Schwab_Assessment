locals {
  negs = {
    us-central1-b = {
      name   = "app-a-neg-usc1"
      region = "us-central1"
    }
    us-central1-c = {
      name   = "app-a-neg-usc1"
      region = "us-central1"
    }
    us-central1-f = {
      name   = "app-a-neg-usc1"
      region = "us-central1"
    }
    us-east4-a = {
      name   = "app-a-neg-use4"
      region = "us-east4"
    }
    us-east4-b = {
      name   = "app-a-neg-use4"
      region = "us-east4"
    }
    us-east4-c = {
      name   = "app-a-neg-use4"
      region = "us-east4"
    }
  }

  global_outputs     = data.terraform_remote_state.global.outputs
  domain_name        = trimsuffix(lower(try(trimspace(local.global_outputs.domain_name), "")), ".")
  certificate_map_id = try(trimspace(local.global_outputs.certificate_map_id), "")
  tls_enabled        = local.certificate_map_id != "" && local.domain_name != ""
  certificate_map_uri = local.tls_enabled ? (
    startswith(local.certificate_map_id, "//certificatemanager.googleapis.com/")
    ? local.certificate_map_id
    : "//certificatemanager.googleapis.com/${local.certificate_map_id}"
  ) : null

  labels = {
    managed_by = "terraform"
    workload   = "risk-assessment"
  }
}

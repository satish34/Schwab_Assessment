locals {
  regional_cells = {
    us-central1 = {
      subnet_name        = "risk-usc1"
      primary_cidr       = "10.10.0.0/20"
      pod_range_name     = "risk-usc1-pods"
      pod_cidr           = "10.20.0.0/16"
      service_range_name = "risk-usc1-services"
      service_cidr       = "10.30.0.0/20"
      node_account_id    = "risk-gke-usc1-nodes"
      node_display_name  = "GKE us-central1 node identity"
    }
    us-east4 = {
      subnet_name        = "risk-use4"
      primary_cidr       = "10.11.0.0/20"
      pod_range_name     = "risk-use4-pods"
      pod_cidr           = "10.21.0.0/16"
      service_range_name = "risk-use4-services"
      service_cidr       = "10.31.0.0/20"
      node_account_id    = "risk-gke-use4-nodes"
      node_display_name  = "GKE us-east4 node identity"
    }
  }

  domain_name = trimsuffix(lower(trimspace(var.domain_name)), ".")
  tls_enabled = local.domain_name != ""

  labels = {
    managed_by = "terraform"
    workload   = "risk-assessment"
  }
}

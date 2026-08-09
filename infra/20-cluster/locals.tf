locals {
  cells = {
    us-central1 = {
      cluster_name = "gke-risk-usc1"
      node_locations = [
        "us-central1-a",
        "us-central1-b",
        "us-central1-c",
      ]
      subnet_name        = "risk-usc1"
      pod_range_name     = "risk-usc1-pods"
      service_range_name = "risk-usc1-services"
      master_cidr        = "172.16.0.0/28"
      node_account_id    = "risk-gke-usc1-nodes"
    }
    us-east4 = {
      cluster_name = "gke-risk-use4"
      node_locations = [
        "us-east4-a",
        "us-east4-b",
        "us-east4-c",
      ]
      subnet_name        = "risk-use4"
      pod_range_name     = "risk-use4-pods"
      service_range_name = "risk-use4-services"
      master_cidr        = "172.16.0.16/28"
      node_account_id    = "risk-gke-use4-nodes"
    }
  }

  labels = {
    managed_by = "terraform"
    workload   = "risk-assessment"
  }
}

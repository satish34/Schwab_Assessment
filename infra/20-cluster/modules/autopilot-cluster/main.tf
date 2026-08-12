resource "google_container_cluster" "this" {
  project = var.project_id

  name           = var.name
  description    = "Regional risk-assessment cell in ${var.region}."
  location       = var.region
  node_locations = var.node_locations

  enable_autopilot    = true
  deletion_protection = false

  network           = var.network_self_link
  subnetwork        = var.subnetwork_self_link
  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH"

  resource_labels = var.labels

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pod_range_name
    services_secondary_range_name = var.service_range_name
    stack_type                    = "IPV4"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr

    master_global_access_config {
      enabled = false
    }
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    cidr_blocks {
      cidr_block   = var.admin_cidr
      display_name = "assessment-admin"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  dynamic "binary_authorization" {
    for_each = var.enable_binary_authorization ? [true] : []

    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = var.node_service_account_email
    }
  }

  logging_config {
    enable_components = [
      "APISERVER",
      "CONTROLLER_MANAGER",
      "KCP_HPA",
      "SCHEDULER",
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
    ]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
}

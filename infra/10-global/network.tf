resource "google_compute_network" "risk" {
  project = google_project.current.project_id
  name    = "risk-vpc"

  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "cell" {
  for_each = local.regional_cells

  project       = google_project.current.project_id
  name          = each.value.subnet_name
  region        = each.key
  network       = google_compute_network.risk.id
  ip_cidr_range = each.value.primary_cidr

  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"

  secondary_ip_range {
    range_name    = each.value.pod_range_name
    ip_cidr_range = each.value.pod_cidr
  }

  secondary_ip_range {
    range_name    = each.value.service_range_name
    ip_cidr_range = each.value.service_cidr
  }
}

resource "google_compute_global_address" "risk" {
  project = google_project.current.project_id
  name    = "risk-global-ip"

  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_firewall" "health_checks" {
  project = google_project.current.project_id
  name    = "risk-allow-gfe-to-app-a"
  network = google_compute_network.risk.name

  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_service_accounts = [
    for account in google_service_account.node : account.email
  ]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_health_check" "app_a_cell" {
  project = var.project_id
  name    = "risk-app-a-cell-health"

  description         = "Dependency-aware App A cell health."
  check_interval_sec  = 5
  timeout_sec         = 2
  unhealthy_threshold = 2
  healthy_threshold   = 3
  deletion_policy     = "DELETE"

  http_health_check {
    request_path       = "/health/cell"
    port_specification = "USE_SERVING_PORT"
    proxy_header       = "NONE"
  }

  log_config {
    enable = true
  }

  depends_on = [terraform_data.global_contract]
}

resource "google_compute_backend_service" "app_a" {
  project = var.project_id
  name    = "risk-app-a-gateway-backend"

  description                     = "Active-active App A pod backends in both regional cells."
  protocol                        = "HTTP"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  locality_lb_policy              = "ROUND_ROBIN"
  session_affinity                = "NONE"
  timeout_sec                     = 10
  connection_draining_timeout_sec = 30
  health_checks                   = [google_compute_health_check.app_a_cell.id]
  deletion_policy                 = "DELETE"

  dynamic "backend" {
    for_each = data.google_compute_network_endpoint_group.app_a

    content {
      group                 = backend.value.self_link
      balancing_mode        = "RATE"
      max_rate_per_endpoint = 20
      capacity_scaler       = 1.0
    }
  }

  depends_on = [terraform_data.neg_contract]
}

resource "google_compute_url_map" "application" {
  project = var.project_id
  name    = "risk-app-a-gateway-map"

  description     = "Route all application traffic to App A."
  default_service = google_compute_backend_service.app_a.id
  deletion_policy = "DELETE"
}

resource "google_compute_target_http_proxy" "application" {
  count = local.tls_enabled ? 0 : 1

  project = var.project_id
  name    = "risk-app-a-http-proxy"

  # Keep the legacy metadata stable for no-domain recovery plans.
  description     = "Serve the core HTTP endpoint."
  url_map         = google_compute_url_map.application.id
  deletion_policy = "DELETE"
}

resource "google_compute_global_forwarding_rule" "http" {
  count = local.tls_enabled ? 0 : 1

  project = var.project_id
  name    = "risk-app-a-http"

  # Keep the legacy metadata stable for no-domain recovery plans.
  description           = "Public HTTP application endpoint."
  ip_address            = local.global_outputs.global_ipv4_address
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  target                = google_compute_target_http_proxy.application[0].id
  labels                = local.labels
  deletion_policy       = "DELETE"
}

resource "google_compute_target_https_proxy" "application" {
  count = local.tls_enabled ? 1 : 0

  project = var.project_id
  name    = "risk-app-a-https-proxy"

  description     = "Serve the application with the trusted Certificate Manager map."
  url_map         = google_compute_url_map.application.id
  certificate_map = local.certificate_map_uri
  quic_override   = "NONE"
  deletion_policy = "DELETE"
}

resource "google_compute_global_forwarding_rule" "https" {
  count = local.tls_enabled ? 1 : 0

  project = var.project_id
  name    = "risk-app-a-https"

  description           = "Public HTTPS application endpoint."
  ip_address            = local.global_outputs.global_ipv4_address
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  target                = google_compute_target_https_proxy.application[0].id
  labels                = local.labels
  deletion_policy       = "DELETE"
}

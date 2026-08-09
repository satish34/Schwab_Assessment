resource "google_dns_managed_zone" "risk" {
  count = local.tls_enabled ? 1 : 0

  project  = google_project.current.project_id
  name     = "risk-public-zone"
  dns_name = "${local.domain_name}."

  description = "Public zone for the assessment endpoint."
  visibility  = "public"
  labels      = local.labels
}

resource "google_dns_record_set" "public_ipv4" {
  count = local.tls_enabled ? 1 : 0

  project      = google_project.current.project_id
  managed_zone = google_dns_managed_zone.risk[0].name
  name         = "${local.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.risk.address]
}

resource "google_certificate_manager_dns_authorization" "risk" {
  count = local.tls_enabled ? 1 : 0

  project = google_project.current.project_id
  name    = "risk-dns-auth"
  domain  = local.domain_name
}

resource "google_dns_record_set" "certificate_authorization" {
  count = local.tls_enabled ? 1 : 0

  project      = google_project.current.project_id
  managed_zone = google_dns_managed_zone.risk[0].name
  name         = google_certificate_manager_dns_authorization.risk[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.risk[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.risk[0].dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "risk" {
  count = local.tls_enabled ? 1 : 0

  project = google_project.current.project_id
  name    = "risk-cert"

  managed {
    domains            = [local.domain_name]
    dns_authorizations = [google_certificate_manager_dns_authorization.risk[0].id]
  }

  depends_on = [google_dns_record_set.certificate_authorization]
}

resource "google_certificate_manager_certificate_map" "risk" {
  count = local.tls_enabled ? 1 : 0

  project = google_project.current.project_id
  name    = "risk-cert-map"
}

resource "google_certificate_manager_certificate_map_entry" "risk" {
  count = local.tls_enabled ? 1 : 0

  project      = google_project.current.project_id
  name         = "risk-domain"
  map          = google_certificate_manager_certificate_map.risk[0].name
  hostname     = local.domain_name
  certificates = [google_certificate_manager_certificate.risk[0].id]
}

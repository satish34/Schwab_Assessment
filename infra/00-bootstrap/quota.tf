resource "google_cloud_quotas_quota_preference" "gke_all_regions_cpu_capacity" {
  parent   = "projects/${var.project_id}"
  name     = "compute-cpus-all-regions-96"
  service  = "compute.googleapis.com"
  quota_id = "CPUS-ALL-REGIONS-per-project"

  contact_email = "satish.cse7@gmail.com"
  justification = "Run two three-zone GKE Autopilot assessment cells within one project."

  quota_config {
    preferred_value = "96"
  }

  # The Cloud Quotas API does not round-trip request-only metadata, and the
  # provider normalizes an omitted safety-check value after creation. The
  # quota, service, scope, and preferred value remain fully drift-checked.
  lifecycle {
    ignore_changes = [contact_email, justification, ignore_safety_checks]
  }

  depends_on = [
    google_project_service.required["cloudquotas.googleapis.com"],
    google_project_service.required["compute.googleapis.com"],
  ]
}

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

locals {
  # Autopilot currently provisions 100-GB balanced persistent disks for these
  # nodes. A 900-GB regional ceiling covers the observed five-node steady cell
  # plus one surge slot for each of the four Deployments reconciled in parallel,
  # without weakening maxUnavailable=0.
  gke_regional_ssd_quota_gb = 900
  gke_regions               = toset(["us-central1", "us-east4"])
}

resource "google_cloud_quotas_quota_preference" "gke_regional_ssd_capacity" {
  for_each = local.gke_regions

  parent   = "projects/${var.project_id}"
  name     = "compute-ssd-total-gb-${each.key}"
  service  = "compute.googleapis.com"
  quota_id = "SSD-TOTAL-GB-per-project-region"
  dimensions = {
    region = each.key
  }

  contact_email = "satish.cse7@gmail.com"
  justification = "Allow four temporary GKE Autopilot surge nodes in ${each.key} while preserving zonal availability."

  quota_config {
    preferred_value = tostring(local.gke_regional_ssd_quota_gb)
  }

  # Request-only metadata is not returned by Cloud Quotas. Keep the service,
  # quota ID, regional dimension, and preferred value fully drift-checked.
  lifecycle {
    ignore_changes = [contact_email, justification, ignore_safety_checks]
  }

  depends_on = [
    google_project_service.required["cloudquotas.googleapis.com"],
    google_project_service.required["compute.googleapis.com"],
  ]
}

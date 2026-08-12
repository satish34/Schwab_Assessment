resource "google_bigquery_dataset" "platform_logs" {
  project = google_project.current.project_id

  dataset_id    = "currency_platform_logs"
  friendly_name = "Currency platform logs"
  description   = "Sampled GKE control-plane, node, edge, VPC, firewall, and health-check logs."
  location      = "US"

  default_partition_expiration_ms = 2592000000
  max_time_travel_hours           = 48
  delete_contents_on_destroy      = true
  labels                          = local.labels
}

resource "google_logging_project_sink" "platform" {
  project = google_project.current.project_id

  name        = "currency-platform-to-bigquery"
  description = "Routes a bounded platform-log sample to a separate partitioned BigQuery dataset."
  destination = "bigquery.googleapis.com/projects/${google_project.current.project_id}/datasets/${google_bigquery_dataset.platform_logs.dataset_id}"

  unique_writer_identity = true
  filter                 = <<-EOT
    (
      (
        (resource.type="k8s_control_plane_component" OR resource.type="k8s_node")
        AND NOT (log_id("stdout") OR log_id("stderr"))
        AND sample(insertId, 0.10)
      )
      OR (resource.type="http_load_balancer" AND log_id("requests"))
      OR log_id("compute.googleapis.com/vpc_flows")
      OR (log_id("compute.googleapis.com/firewall") AND sample(insertId, 0.10))
      OR log_id("compute.googleapis.com/healthchecks")
    )
  EOT

  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "platform_sink_writer" {
  project    = google_project.current.project_id
  dataset_id = google_bigquery_dataset.platform_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.platform.writer_identity
}

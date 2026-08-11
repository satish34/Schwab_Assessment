resource "google_bigquery_dataset" "risk_logs" {
  project = google_project.current.project_id

  dataset_id    = "risk_logs"
  friendly_name = "Risk application logs"
  description   = "Partitioned structured stdout logs for App A and App B."
  location      = "US"

  delete_contents_on_destroy = true
  labels                     = local.labels
}

resource "google_logging_project_sink" "application_stdout" {
  project = google_project.current.project_id

  name        = "risk-app-stdout-to-bigquery"
  description = "Routes structured risk application stdout to BigQuery."
  destination = "bigquery.googleapis.com/projects/${google_project.current.project_id}/datasets/${google_bigquery_dataset.risk_logs.dataset_id}"

  unique_writer_identity = true
  filter                 = <<-EOT
    resource.type="k8s_container"
    (resource.labels.namespace_name="currency-app-a" OR resource.labels.namespace_name="currency-app-b")
    log_id("stdout")
    (jsonPayload.service="app-a-gateway" OR jsonPayload.service="app-b-engine")
  EOT

  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "sink_writer" {
  project    = google_project.current.project_id
  dataset_id = google_bigquery_dataset.risk_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.application_stdout.writer_identity
}

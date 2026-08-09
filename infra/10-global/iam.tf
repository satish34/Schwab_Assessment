resource "google_service_account" "node" {
  for_each = local.regional_cells

  project      = google_project.current.project_id
  account_id   = each.value.node_account_id
  display_name = each.value.node_display_name
  description  = "Least-privilege Autopilot node identity for ${each.key}."
}

resource "google_project_iam_member" "node_runtime" {
  for_each = google_service_account.node

  project = google_project.current.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = each.value.member

  depends_on = [google_project_default_service_accounts.defaults]
}

resource "google_artifact_registry_repository_iam_member" "node_image_pull" {
  for_each = google_service_account.node

  project    = google_project.current.project_id
  location   = google_artifact_registry_repository.risk.location
  repository = google_artifact_registry_repository.risk.repository_id
  role       = "roles/artifactregistry.reader"
  member     = each.value.member
}

resource "google_service_account" "build" {
  project = google_project.current.project_id

  account_id   = "risk-cloud-build"
  display_name = "Risk application image builder"
  description  = "Runs tests and publishes immutable assessment images."
}

resource "google_artifact_registry_repository_iam_member" "build_image_push" {
  project    = google_project.current.project_id
  location   = google_artifact_registry_repository.risk.location
  repository = google_artifact_registry_repository.risk.repository_id
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.build.member
}

resource "google_project_iam_member" "build_logging" {
  project = google_project.current.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.build.member

  depends_on = [google_project_default_service_accounts.defaults]
}

resource "google_service_account" "grafana_reader" {
  project = google_project.current.project_id

  account_id   = "grafana-reader"
  display_name = "Grafana read-only data source"
  description  = "Reads assessment logs and monitoring metrics; no key is created by Terraform."
}

resource "google_bigquery_dataset_iam_member" "grafana_reader" {
  project    = google_project.current.project_id
  dataset_id = google_bigquery_dataset.risk_logs.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.grafana_reader.member
}

resource "google_project_iam_member" "grafana_reader" {
  for_each = toset([
    "roles/bigquery.jobUser",
    "roles/monitoring.viewer",
  ])

  project = google_project.current.project_id
  role    = each.value
  member  = google_service_account.grafana_reader.member

  depends_on = [google_project_default_service_accounts.defaults]
}

resource "google_project_iam_custom_role" "grafana_project_reader" {
  project = google_project.current.project_id

  role_id     = "grafanaProjectReader"
  title       = "Grafana Project Reader"
  description = "Allows Grafana to resolve only the project metadata it needs."
  permissions = ["resourcemanager.projects.get"]
  stage       = "GA"
}

resource "google_project_iam_member" "grafana_project_reader" {
  project = google_project.current.project_id
  role    = google_project_iam_custom_role.grafana_project_reader.name
  member  = google_service_account.grafana_reader.member

  depends_on = [google_project_default_service_accounts.defaults]
}

resource "google_service_account_iam_member" "grafana_operator_impersonation" {
  service_account_id = google_service_account.grafana_reader.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:satish.cse7@gmail.com"
}

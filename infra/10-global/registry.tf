resource "google_artifact_registry_repository" "risk" {
  project = google_project.current.project_id

  location      = "us-central1"
  repository_id = "risk"
  description   = "Immutable assessment application images"
  format        = "DOCKER"

  labels = local.labels

  docker_config {
    immutable_tags = true
  }
}

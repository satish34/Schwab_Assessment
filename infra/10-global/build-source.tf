resource "google_storage_bucket" "build_source" {
  project = google_project.current.project_id

  name                        = "${google_project.current.project_id}_cloudbuild"
  location                    = "US"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age            = 7
      matches_prefix = ["source/"]
    }
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }
}

resource "google_storage_bucket_iam_member" "build_source_read" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.build.member
}

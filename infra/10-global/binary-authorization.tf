resource "google_binary_authorization_policy" "assessment" {
  count = var.enable_binary_authorization ? 1 : 0

  project = google_project.current.project_id

  description                   = "Only assessment runtime images and Google-managed system images may run."
  global_policy_evaluation_mode = "ENABLE"

  admission_whitelist_patterns {
    name_pattern = "us-central1-docker.pkg.dev/${google_project.current.project_id}/${google_artifact_registry_repository.risk.repository_id}/app-a"
  }

  admission_whitelist_patterns {
    name_pattern = "us-central1-docker.pkg.dev/${google_project.current.project_id}/${google_artifact_registry_repository.risk.repository_id}/app-b"
  }

  admission_whitelist_patterns {
    name_pattern = "us-central1-docker.pkg.dev/${google_project.current.project_id}/${google_artifact_registry_repository.risk.repository_id}/grafana-evidence"
  }

  default_admission_rule {
    evaluation_mode  = "ALWAYS_DENY"
    enforcement_mode = "ENFORCED_BLOCK_AND_AUDIT_LOG"
  }
}

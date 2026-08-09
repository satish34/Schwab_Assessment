import {
  id = var.project_id
  to = google_project.current
}

resource "google_project" "current" {
  name            = "Schwab Assessment"
  project_id      = var.project_id
  billing_account = var.billing_account_id

  # Keep the desired project setting explicit. The provider only performs the
  # delete during project creation, so the guarded migration below handles the
  # already-created project.
  auto_create_network = false

  # This stack adopts the existing project only for baseline settings. Its
  # destroy path must never delete the project.
  deletion_policy = "ABANDON"
}

# google_project does not delete a default VPC when an existing project is
# imported. Run the checked, idempotent migration once per adopted project.
resource "terraform_data" "default_network_absent" {
  triggers_replace = [google_project.current.project_id]

  provisioner "local-exec" {
    command     = "\"${path.module}/../../scripts/remove-default-network.sh\" apply"
    interpreter = ["bash", "-c"]

    environment = {
      ALLOW_DEFAULT_NETWORK_DELETE = "1"
      GCLOUD_CONFIGURATION         = var.gcloud_configuration
      PROJECT_ID                   = google_project.current.project_id
    }
  }
}

resource "google_project_default_service_accounts" "defaults" {
  project        = google_project.current.project_id
  action         = "DEPRIVILEGE"
  restore_policy = "NONE"
}

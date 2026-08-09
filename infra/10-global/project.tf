import {
  id = var.project_id
  to = google_project.current
}

resource "google_project" "current" {
  name            = "Schwab Assessment"
  project_id      = var.project_id
  billing_account = var.billing_account_id

  # Enabling Compute created an unused default VPC. Managing the existing
  # project is the GA provider's stable way to remove it without shell drift.
  auto_create_network = false

  # This stack adopts the existing project only for baseline settings. Its
  # destroy path must never delete the project.
  deletion_policy = "ABANDON"
}

resource "google_project_default_service_accounts" "defaults" {
  project        = google_project.current.project_id
  action         = "DEPRIVILEGE"
  restore_policy = "NONE"
}

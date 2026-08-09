locals {
  core_services = toset([
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbuild.googleapis.com",
    "clouderrorreporting.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
  ])

  tls_services = trimspace(var.domain_name) == "" ? toset([]) : toset([
    "certificatemanager.googleapis.com",
    "dns.googleapis.com",
  ])

  required_services = setunion(local.core_services, local.tls_services)
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project = var.project_id
  service = each.value

  disable_dependent_services = false
  # Keep APIs available for the final orphan check. Project deletion, if
  # requested, is the last cleanup action.
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id

  depends_on = [
    google_project_service.required["cloudresourcemanager.googleapis.com"],
  ]
}

resource "google_billing_budget" "safety" {
  billing_account = var.billing_account_id
  display_name    = "Schwab Assessment - 30 USD Safety Budget"

  budget_filter {
    projects        = ["projects/${data.google_project.current.number}"]
    calendar_period = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.budget_thresholds

    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  depends_on = [
    google_project_service.required["billingbudgets.googleapis.com"],
  ]
}

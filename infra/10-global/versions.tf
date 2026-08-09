terraform {
  required_version = ">= 1.8, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.43.0"
    }
  }
}

provider "google" {
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
}

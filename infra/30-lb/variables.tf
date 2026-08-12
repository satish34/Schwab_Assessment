variable "project_id" {
  description = "Dedicated Google Cloud project ID. Must match the 10-global state."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "enable_cloud_armor" {
  description = "Create and attach the opt-in Cloud Armor policy; its evidence mode raises backend request logging from 5% to 100%."
  type        = bool
  default     = false
}

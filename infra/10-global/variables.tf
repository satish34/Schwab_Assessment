variable "project_id" {
  description = "Dedicated Google Cloud project ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account already linked to the project."
  type        = string
  sensitive   = true
}

variable "gcloud_configuration" {
  description = "Named gcloud configuration already verified by the wrapper."
  type        = string
}

variable "domain_name" {
  description = "Optional owned domain or delegated subdomain for trusted HTTPS."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.domain_name) == "" ||
      can(regex(
        "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\\.?$",
        lower(trimspace(var.domain_name))
      ))
    )
    error_message = "domain_name must be empty or a DNS name without a scheme or path."
  }
}

variable "project_id" {
  description = "Dedicated Google Cloud project ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account that owns the safety budget."
  type        = string
  sensitive   = true
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

variable "enable_binary_authorization" {
  description = "Enable the paid Binary Authorization APIs for the opt-in hardening demonstration."
  type        = bool
  default     = false
}

variable "budget_amount_usd" {
  description = "Monthly project safety budget in USD."
  type        = number
  default     = 30

  validation {
    condition     = var.budget_amount_usd == 30
    error_message = "The assessment safety budget is frozen at 30 USD."
  }
}

variable "budget_thresholds" {
  description = "Current-spend alert thresholds."
  type        = set(number)
  default     = [0.5, 0.8, 0.9, 1.0]
}

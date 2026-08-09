variable "project_id" {
  description = "Dedicated Google Cloud project ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account that owns the safety budget."
  type        = string
  sensitive   = true
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

variable "project_id" {
  description = "Dedicated Google Cloud project ID. Must match the 10-global state."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "admin_cidr" {
  description = "Single public IPv4 address allowed to reach both GKE control planes."
  type        = string

  validation {
    condition = (
      can(cidrhost(trimspace(var.admin_cidr), 0)) &&
      can(regex("/32$", trimspace(var.admin_cidr))) &&
      !strcontains(trimspace(var.admin_cidr), ":") &&
      trimspace(var.admin_cidr) != "0.0.0.0/32"
    )
    error_message = "admin_cidr must be one specific public IPv4 address in /32 notation; 0.0.0.0/32 is not allowed."
  }
}

variable "enable_binary_authorization" {
  description = "Enable project-policy Binary Authorization enforcement on both clusters."
  type        = bool
  default     = false
}

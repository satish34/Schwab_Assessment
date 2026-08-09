variable "project_id" {
  type = string
}

variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "node_locations" {
  type = list(string)
}

variable "network_self_link" {
  type = string
}

variable "subnetwork_self_link" {
  type = string
}

variable "pod_range_name" {
  type = string
}

variable "service_range_name" {
  type = string
}

variable "master_cidr" {
  type = string
}

variable "admin_cidr" {
  type = string
}

variable "node_service_account_email" {
  type = string
}

variable "labels" {
  type    = map(string)
  default = {}
}

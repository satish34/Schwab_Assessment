output "backend_service_name" {
  value = google_compute_backend_service.app_a.name
}

output "backend_service_self_link" {
  value = google_compute_backend_service.app_a.self_link
}

output "health_check_name" {
  value = google_compute_health_check.app_a_cell.name
}

output "security_policy_name" {
  value = var.enable_cloud_armor ? google_compute_security_policy.currency_edge[0].name : null
}

output "cloud_armor_enabled" {
  value = var.enable_cloud_armor
}

output "global_ipv4_address" {
  value = local.global_outputs.global_ipv4_address
}

output "public_endpoint" {
  value = local.tls_enabled ? "https://${local.domain_name}" : "http://${local.global_outputs.global_ipv4_address}"
}

output "tls_enabled" {
  value = local.tls_enabled
}

output "forwarding_rule_names" {
  value = {
    http  = local.tls_enabled ? null : google_compute_global_forwarding_rule.http[0].name
    https = local.tls_enabled ? google_compute_global_forwarding_rule.https[0].name : null
  }
}

output "neg_backends" {
  value = {
    for zone, neg in data.google_compute_network_endpoint_group.app_a : zone => {
      name      = neg.name
      region    = local.negs[zone].region
      self_link = neg.self_link
      endpoints = neg.size
    }
  }
}

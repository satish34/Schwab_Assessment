output "project_id" {
  value = google_project.current.project_id
}

output "project_number" {
  value = google_project.current.number
}

output "network_name" {
  value = google_compute_network.risk.name
}

output "network_self_link" {
  value = google_compute_network.risk.self_link
}

output "subnetwork_names" {
  value = { for region, subnet in google_compute_subnetwork.cell : region => subnet.name }
}

output "subnetwork_self_links" {
  value = { for region, subnet in google_compute_subnetwork.cell : region => subnet.self_link }
}

output "secondary_ranges" {
  value = {
    for region, cell in local.regional_cells : region => {
      pods     = cell.pod_range_name
      services = cell.service_range_name
    }
  }
}

output "artifact_registry_repository" {
  value = "us-central1-docker.pkg.dev/${google_project.current.project_id}/${google_artifact_registry_repository.risk.repository_id}"
}

output "global_address_name" {
  value = google_compute_global_address.risk.name
}

output "global_ipv4_address" {
  value = google_compute_global_address.risk.address
}

output "health_firewall_name" {
  value = google_compute_firewall.health_checks.name
}

output "bigquery_dataset_id" {
  value = google_bigquery_dataset.risk_logs.dataset_id
}

output "log_sink_name" {
  value = google_logging_project_sink.application_stdout.name
}

output "log_sink_writer_identity" {
  value = google_logging_project_sink.application_stdout.writer_identity
}

output "grafana_reader_email" {
  value = google_service_account.grafana_reader.email
}

output "build_service_account_email" {
  value = google_service_account.build.email
}

output "build_source_bucket" {
  value = google_storage_bucket.build_source.name
}

output "node_service_account_emails" {
  value = { for region, account in google_service_account.node : region => account.email }
}

output "default_service_accounts_deprivileged" {
  value = google_project_default_service_accounts.defaults.service_accounts
}

output "dns_name_servers" {
  value = local.tls_enabled ? google_dns_managed_zone.risk[0].name_servers : []
}

output "domain_name" {
  value = local.tls_enabled ? local.domain_name : ""
}

output "certificate_map_id" {
  value = local.tls_enabled ? google_certificate_manager_certificate_map.risk[0].id : ""
}

output "clusters" {
  description = "Regional cluster connection and firewall-targeting contract."
  value = {
    for region, cluster in module.autopilot_cluster : region => {
      name                       = cluster.name
      location                   = cluster.location
      project                    = cluster.project
      network                    = cluster.network
      subnet                     = cluster.subnet
      node_service_account_email = cluster.node_service_account_email
    }
  }
}

output "cluster_names" {
  value = { for region, cluster in module.autopilot_cluster : region => cluster.name }
}

output "cluster_locations" {
  value = { for region, cluster in module.autopilot_cluster : region => cluster.location }
}

output "node_service_account_emails" {
  value = {
    for region, cluster in module.autopilot_cluster : region => cluster.node_service_account_email
  }
}

output "name" {
  value = google_container_cluster.this.name
}

output "location" {
  value = google_container_cluster.this.location
}

output "project" {
  value = google_container_cluster.this.project
}

output "network" {
  value = google_container_cluster.this.network
}

output "subnet" {
  value = google_container_cluster.this.subnetwork
}

output "node_service_account_email" {
  value = google_container_cluster.this.cluster_autoscaling[0].auto_provisioning_defaults[0].service_account
}

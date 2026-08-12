output "project_id" {
  value = data.google_project.current.project_id
}

output "project_number" {
  value = data.google_project.current.number
}

output "budget_name" {
  value = google_billing_budget.safety.name
}

output "enabled_services" {
  value = sort([for service in google_project_service.required : service.service])
}

output "gke_all_regions_cpu_quota" {
  value = {
    name            = google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity.name
    service         = google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity.service
    quota_id        = google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity.quota_id
    preferred_value = tonumber(google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity.quota_config[0].preferred_value)
    granted_value   = try(tonumber(google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity.quota_config[0].granted_value), null)
    reconciling     = google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity.reconciling
  }
}

output "gke_regional_ssd_quotas" {
  value = {
    for region, preference in google_cloud_quotas_quota_preference.gke_regional_ssd_capacity : region => {
      name            = preference.name
      service         = preference.service
      quota_id        = preference.quota_id
      dimensions      = preference.dimensions
      preferred_value = tonumber(preference.quota_config[0].preferred_value)
      granted_value   = try(tonumber(preference.quota_config[0].granted_value), null)
      reconciling     = preference.reconciling
    }
  }
}

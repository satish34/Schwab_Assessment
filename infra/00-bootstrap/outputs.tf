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

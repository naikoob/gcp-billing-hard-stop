output "budget_name" {
  description = "Resource name of the provisioned Cloud Billing Budget"
  value       = google_billing_budget.project_budget.name
}

output "pubsub_topic_id" {
  description = "Pub/Sub topic ID receiving Cloud Billing Budget telemetry"
  value       = google_pubsub_topic.budget_alerts.id
}

output "enforcer_function_name" {
  description = "Name of the Cloud Run function (2nd Gen) enforcing the billing hard stop"
  value       = google_cloudfunctions2_function.billing_enforcer.name
}

output "enforcer_function_uri" {
  description = "Internal URI of the deployed Cloud Function (2nd Gen)"
  value       = google_cloudfunctions2_function.billing_enforcer.service_config[0].uri
}

output "enforcer_service_account_email" {
  description = "Email of the service account executing hard-stop actions"
  value       = google_service_account.billing_enforcer.email
}

output "manual_billing_admin_grant_command" {
  description = "Run this command as a Billing Account Administrator if enforcement_mode = UNLINK_BILLING and grant_billing_account_iam = false"
  value       = "gcloud beta billing accounts add-iam-policy-binding ${var.billing_account_id} --member='serviceAccount:${google_service_account.billing_enforcer.email}' --role='roles/billing.admin'"
}

output "test_warning_alert_command" {
  description = "gcloud command to simulate an 80% warning alert without triggering a hard stop"
  value       = "gcloud pubsub topics publish ${google_pubsub_topic.budget_alerts.name} --project=${var.project_id} --message='{\"budgetDisplayName\":\"${local.budget_name}\",\"costAmount\":${var.monthly_budget_amount * 0.8},\"costIntervalStart\":\"2026-10-01T00:00:00Z\",\"budgetAmount\":${var.monthly_budget_amount},\"budgetAmountType\":\"SPECIFIED_AMOUNT\",\"currencyCode\":\"${var.budget_currency != "" ? var.budget_currency : "USD"}\",\"alertThresholdExceeded\":0.8}'"
}

output "test_hard_stop_breach_command" {
  description = "gcloud command to simulate a 100%+ budget breach (CAUTION: triggers active enforcement_mode)"
  value       = "gcloud pubsub topics publish ${google_pubsub_topic.budget_alerts.name} --project=${var.project_id} --message='{\"budgetDisplayName\":\"${local.budget_name}\",\"costAmount\":${var.monthly_budget_amount * 1.05},\"costIntervalStart\":\"2026-10-01T00:00:00Z\",\"budgetAmount\":${var.monthly_budget_amount},\"budgetAmountType\":\"SPECIFIED_AMOUNT\",\"currencyCode\":\"${var.budget_currency != "" ? var.budget_currency : "USD"}\",\"alertThresholdExceeded\":1.0}'"
}


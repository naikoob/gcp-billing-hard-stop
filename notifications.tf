# ------------------------------------------------------------------------------
# 1. Central Pub/Sub Topic for Cloud Billing Budget Notifications
# ------------------------------------------------------------------------------
resource "google_pubsub_topic" "budget_alerts" {
  name    = "top-${var.project_id}-budget-alerts"
  project = var.project_id

  labels = {
    environment = var.environment
    purpose     = "billing-hard-stop-guardrail"
    managed_by  = "terraform"
  }

  depends_on = [google_project_service.required["pubsub.googleapis.com"]]
}

# ------------------------------------------------------------------------------
# 2. Cloud Monitoring Email Notification Channels (Up to 5 Recipients)
# ------------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "budget_emails" {
  for_each     = toset(var.alert_emails)
  project      = var.project_id
  display_name = "Billing Alert Email (${each.value})"
  type         = "email"

  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.required["monitoring.googleapis.com"]]
}

# ------------------------------------------------------------------------------
# 3. Secret Manager: Slack Incoming Webhook URL (Optional)
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "slack_webhook" {
  count     = var.enable_slack_webhook ? 1 : 0
  secret_id = "sec-${var.project_id}-billing-slack-webhook"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    purpose     = "billing-slack-alerts"
    managed_by  = "terraform"
  }

  depends_on = [google_project_service.required["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "slack_webhook_version" {
  count       = (var.enable_slack_webhook && var.slack_webhook_url != "") ? 1 : 0
  secret      = google_secret_manager_secret.slack_webhook[0].id
  secret_data = var.slack_webhook_url
}


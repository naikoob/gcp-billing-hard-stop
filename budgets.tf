# ------------------------------------------------------------------------------
# Project Metadata & Ordered Google Cloud API Enablement
# (Chained serviceusage -> cloudresourcemanager -> downstream APIs to prevent
#  chicken-and-egg 403 errors on fresh GCP projects)
# ------------------------------------------------------------------------------
resource "google_project_service" "serviceusage" {
  project            = var.project_id
  service            = "serviceusage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.serviceusage]
}

data "google_project" "target" {
  project_id = var.project_id

  depends_on = [google_project_service.cloudresourcemanager]
}

locals {
  downstream_services = toset([
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "orgpolicy.googleapis.com",
    "compute.googleapis.com",
    "pubsub.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
  ])

  budget_name = var.budget_display_name != "" ? var.budget_display_name : "${var.project_id} Billing Guardrail (${var.environment})"
}

resource "google_project_service" "required" {
  for_each           = local.downstream_services
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false

  depends_on = [google_project_service.cloudresourcemanager]
}

# ------------------------------------------------------------------------------
# Optional Project-Level Domain Restricted Sharing Override for Billing Pub/Sub
# ------------------------------------------------------------------------------
# Cloud Billing Budgets uses a legacy global service account
# (`billing-budget-alert@system.gserviceaccount.com`) when attaching a Pub/Sub
# topic to a budget. Organizations enforcing `constraints/iam.allowedPolicyMemberDomains`
# reject that SetIamPolicy call unless the constraint is overridden on the project
# (either permanently via this resource or temporarily via gcloud during creation).
resource "google_project_organization_policy" "allow_billing_pubsub_agent" {
  count      = var.relax_project_drs_for_billing_pubsub ? 1 : 0
  project    = var.project_id
  constraint = "constraints/iam.allowedPolicyMemberDomains"

  list_policy {
    allow {
      all = true
    }
  }

  # Wait 15s for Org Policy propagation before Cloud Billing calls SetIamPolicy on the Pub/Sub topic
  provisioner "local-exec" {
    command = "sleep 15"
  }

  depends_on = [google_project_service.required["orgpolicy.googleapis.com"]]
}

# ------------------------------------------------------------------------------
# Cloud Billing Budget with Actual & Forecasted Thresholds + Pub/Sub Trigger
# ------------------------------------------------------------------------------
resource "google_billing_budget" "project_budget" {
  provider        = google.billing
  billing_account = var.billing_account_id
  display_name    = local.budget_name
  ownership_scope = "BILLING_ACCOUNT"

  budget_filter {
    projects               = ["projects/${data.google_project.target.number}"]
    credit_types_treatment = var.credit_types_treatment
    calendar_period        = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency != "" ? var.budget_currency : null
      units         = tostring(var.monthly_budget_amount)
    }
  }

  # Dynamic Actual Spend Thresholds (default: 50%, 80%, 90%, 100%)
  dynamic "threshold_rules" {
    for_each = var.alert_thresholds_actual
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Dynamic Forecasted Spend Thresholds (default: 100%)
  dynamic "threshold_rules" {
    for_each = var.alert_thresholds_forecasted
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "FORECASTED_SPEND"
    }
  }

  # Route budget telemetry to Pub/Sub (for hard-stop + Slack) and Cloud Monitoring Email channels
  all_updates_rule {
    pubsub_topic                   = google_pubsub_topic.budget_alerts.id
    schema_version                 = "1.0"
    disable_default_iam_recipients = length(var.alert_emails) > 0 ? var.disable_default_iam_recipients : false

    monitoring_notification_channels = [
      for ch in google_monitoring_notification_channel.budget_emails : ch.id
    ]
  }

  depends_on = [
    google_project_service.required["billingbudgets.googleapis.com"],
    google_project_service.required["monitoring.googleapis.com"],
    google_pubsub_topic.budget_alerts,
    google_project_organization_policy.allow_billing_pubsub_agent,
  ]
}

# ------------------------------------------------------------------------------
# 1. Dedicated Service Account & Least-Privilege IAM for Hard-Stop Enforcer
# ------------------------------------------------------------------------------
resource "google_service_account" "billing_enforcer" {
  account_id   = "sa-billing-enforcer"
  display_name = "Billing Hard-Stop Enforcer & Alerting Service Account"
  description  = "Executes automated billing hard-stop actions and dispatches Slack budget notifications"
  project      = var.project_id

  depends_on = [google_project_service.cloudresourcemanager]
}

# Always grant log writing and Cloud Run invocation (for Eventarc Pub/Sub trigger)
resource "google_project_iam_member" "enforcer_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

resource "google_project_iam_member" "enforcer_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

# Mode: STOP_COMPUTE_AND_APIS -> Grant Compute Instance Admin + Service Usage Admin
resource "google_project_iam_member" "enforcer_compute_admin" {
  count   = var.enforcement_mode == "STOP_COMPUTE_AND_APIS" ? 1 : 0
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

resource "google_project_iam_member" "enforcer_service_usage_admin" {
  count   = var.enforcement_mode == "STOP_COMPUTE_AND_APIS" ? 1 : 0
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

# Mode: UNLINK_BILLING -> Grant Project Billing Manager + (optional) Billing Account Admin
resource "google_project_iam_member" "enforcer_project_billing_manager" {
  count   = var.enforcement_mode == "UNLINK_BILLING" ? 1 : 0
  project = var.project_id
  role    = "roles/billing.projectManager"
  member  = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

resource "google_billing_account_iam_member" "enforcer_billing_account_admin" {
  count              = (var.enforcement_mode == "UNLINK_BILLING" && var.grant_billing_account_iam) ? 1 : 0
  billing_account_id = var.billing_account_id
  role               = "roles/billing.admin"
  member             = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

# Slack Webhook Secret Accessor (when Slack notifications are enabled)
resource "google_secret_manager_secret_iam_member" "enforcer_secret_accessor" {
  count     = var.enable_slack_webhook ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.slack_webhook[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billing_enforcer.email}"
}

# ------------------------------------------------------------------------------
# 2. Cloud Build Permissions for Cloud Functions 2nd Gen Deployment
# ------------------------------------------------------------------------------
locals {
  compute_default_sa = "serviceAccount:${data.google_project.target.number}-compute@developer.gserviceaccount.com"
  cloudbuild_roles = toset([
    "roles/cloudbuild.builds.builder",
    "roles/logging.logWriter",
    "roles/storage.objectViewer",
    "roles/artifactregistry.writer",
  ])
}

resource "google_project_iam_member" "cloudbuild_permissions" {
  for_each = local.cloudbuild_roles
  project  = var.project_id
  role     = each.value
  member   = local.compute_default_sa

  depends_on = [google_project_service.required["cloudbuild.googleapis.com"]]
}

# ------------------------------------------------------------------------------
# 3. Function Source Packaging & Staging Bucket
# ------------------------------------------------------------------------------
data "archive_file" "enforcer_source_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/.terraform/billing_enforcer_src.zip"
}

resource "google_storage_bucket" "enforcer_source" {
  name                        = "bkt-${var.project_id}-billing-enforcer-src"
  location                    = var.region
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }

  labels = {
    environment = var.environment
    purpose     = "billing-enforcer-source"
    managed_by  = "terraform"
  }
}

resource "google_storage_bucket_object" "enforcer_source_archive" {
  name   = "billing-enforcer-${data.archive_file.enforcer_source_zip.output_md5}.zip"
  bucket = google_storage_bucket.enforcer_source.name
  source = data.archive_file.enforcer_source_zip.output_path
}

# ------------------------------------------------------------------------------
# 4. Cloud Functions 2nd Gen: Billing Hard-Stop Enforcer & Slack Notifier
# ------------------------------------------------------------------------------
resource "google_cloudfunctions2_function" "billing_enforcer" {
  name        = "fn-${var.project_id}-billing-enforcer"
  location    = var.region
  project     = var.project_id
  description = "Evaluates Cloud Billing Budget Pub/Sub events, sends Slack alerts, and enforces hard-stop actions (${var.enforcement_mode})"

  build_config {
    runtime     = "python312"
    entry_point = "handle_budget_notification"
    source {
      storage_source {
        bucket = google_storage_bucket.enforcer_source.name
        object = google_storage_bucket_object.enforcer_source_archive.name
      }
    }
  }

  service_config {
    max_instance_count             = 2
    min_instance_count             = 0
    available_memory               = "256Mi"
    timeout_seconds                = 120
    service_account_email          = google_service_account.billing_enforcer.email
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true

    environment_variables = {
      PROJECT_ID                  = var.project_id
      REGION                      = var.region
      ENFORCEMENT_MODE            = var.enforcement_mode
      HARD_STOP_THRESHOLD_PERCENT = tostring(var.hard_stop_threshold_percent)
      TRIGGER_ON_FORECAST_BREACH  = tostring(var.trigger_on_forecast_breach)
      APIS_TO_DISABLE             = join(",", var.apis_to_disable_on_breach)
      PROTECT_ENFORCER_SERVICES   = tostring(var.protect_enforcer_services)
      ENABLE_SLACK_WEBHOOK        = tostring(var.enable_slack_webhook)
      SLACK_SECRET_ID             = var.enable_slack_webhook ? google_secret_manager_secret.slack_webhook[0].secret_id : ""
      SLACK_CHANNEL_NAME          = var.slack_channel_name
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.budget_alerts.id
    service_account_email = google_service_account.billing_enforcer.email
    # Do not retry endlessly if billing was just unlinked or APIs were disabled
    retry_policy = "RETRY_POLICY_DO_NOT_RETRY"
  }

  depends_on = [
    google_project_service.required["cloudfunctions.googleapis.com"],
    google_project_service.required["run.googleapis.com"],
    google_project_service.required["cloudbuild.googleapis.com"],
    google_project_service.required["eventarc.googleapis.com"],
    google_project_iam_member.cloudbuild_permissions,
    google_project_iam_member.enforcer_run_invoker,
  ]
}

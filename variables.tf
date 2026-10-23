# ------------------------------------------------------------------------------
# Project & Core Settings
# ------------------------------------------------------------------------------
variable "project_id" {
  description = "Target Google Cloud Project ID to monitor and protect with billing guardrails"
  type        = string
}

variable "region" {
  description = "Primary Google Cloud region for Pub/Sub and Cloud Functions (2nd Gen)"
  type        = string
  default     = "asia-southeast1"
}

variable "environment" {
  description = "Environment label (e.g., poc, dev, staging, prod)"
  type        = string
  default     = "poc"
}

# ------------------------------------------------------------------------------
# Cloud Billing & Budget Thresholds
# ------------------------------------------------------------------------------
variable "billing_account_id" {
  description = "Google Cloud Billing Account ID (format: 012345-67890A-BCDEFG)"
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "The billing_account_id must match the standard 6-6-6 hex format (e.g., 012345-67890A-BCDEFG)."
  }
}

variable "budget_display_name" {
  description = "Optional custom display name for the Cloud Billing Budget. Defaults to '<project_id> Billing Guardrail (<environment>)'"
  type        = string
  default     = ""
}

variable "monthly_budget_amount" {
  description = "Monthly budget ceiling amount in whole currency units (e.g., 5000 for 5,000 SGD/USD)"
  type        = number
  default     = 5000

  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "monthly_budget_amount must be greater than 0."
  }
}

variable "budget_currency" {
  description = "ISO 4217 3-letter currency code matching the Cloud Billing Account (e.g., SGD, USD). Leave empty (\"\") to automatically inherit the Billing Account's currency."
  type        = string
  default     = ""
}

variable "credit_types_treatment" {
  description = "How credits (promotional, sustained use, CUDs) are treated in budget calculations (INCLUDE_ALL_CREDITS or EXCLUDE_ALL_CREDITS)"
  type        = string
  default     = "INCLUDE_ALL_CREDITS"

  validation {
    condition     = contains(["INCLUDE_ALL_CREDITS", "EXCLUDE_ALL_CREDITS", "INCLUDE_SPECIFIED_CREDITS"], var.credit_types_treatment)
    error_message = "credit_types_treatment must be INCLUDE_ALL_CREDITS, EXCLUDE_ALL_CREDITS, or INCLUDE_SPECIFIED_CREDITS."
  }
}

variable "alert_thresholds_actual" {
  description = "List of actual spend threshold percentages (as decimals, e.g., 0.50 = 50%) that trigger budget alerts"
  type        = list(number)
  default     = [0.50, 0.80, 0.90, 1.00]
}

variable "alert_thresholds_forecasted" {
  description = "List of forecasted spend threshold percentages (as decimals, e.g., 1.00 = 100%) that trigger proactive alerts"
  type        = list(number)
  default     = [1.00]
}

# ------------------------------------------------------------------------------
# Hard-Stop Enforcement Configuration
# ------------------------------------------------------------------------------
variable "enforcement_mode" {
  description = <<-EOT
    Hard-stop action executed when actual spend reaches hard_stop_threshold_percent:
    - DRY_RUN               : Logs the breach and dispatches alerts without modifying resources or billing.
    - STOP_COMPUTE_AND_APIS : Stops all running Compute Engine VMs and disables high-spend APIs (var.apis_to_disable_on_breach).
    - UNLINK_BILLING        : Detaches the Billing Account from the project (nuclear hard stop; halts all billable services).
  EOT
  type        = string
  default     = "STOP_COMPUTE_AND_APIS"

  validation {
    condition     = contains(["DRY_RUN", "STOP_COMPUTE_AND_APIS", "UNLINK_BILLING"], var.enforcement_mode)
    error_message = "enforcement_mode must be one of: DRY_RUN, STOP_COMPUTE_AND_APIS, UNLINK_BILLING."
  }
}

variable "hard_stop_threshold_percent" {
  description = "Spend ratio (costAmount / budgetAmount) at which the Cloud Function triggers the hard stop (e.g., 1.00 for 100%, or 0.95 for a 95% buffer against billing latency)"
  type        = number
  default     = 1.00

  validation {
    condition     = var.hard_stop_threshold_percent > 0 && var.hard_stop_threshold_percent <= 2.0
    error_message = "hard_stop_threshold_percent must be between 0.0 (exclusive) and 2.0 (inclusive)."
  }
}

variable "trigger_on_forecast_breach" {
  description = "If true, also triggers the hard stop when forecasted spend exceeds hard_stop_threshold_percent (not recommended for UNLINK_BILLING)"
  type        = bool
  default     = false
}

variable "apis_to_disable_on_breach" {
  description = "List of billable Google Cloud APIs to disable when enforcement_mode is STOP_COMPUTE_AND_APIS"
  type        = list(string)
  default = [
    "aiplatform.googleapis.com",
    "compute.googleapis.com",
    "notebooks.googleapis.com",
    "dataflow.googleapis.com"
  ]
}

variable "protect_enforcer_services" {
  description = "Prevent STOP_COMPUTE_AND_APIS from disabling the APIs required by the enforcer function itself (cloudfunctions, run, pubsub, eventarc)"
  type        = bool
  default     = true
}

variable "grant_billing_account_iam" {
  description = "Set to true if the Terraform caller has Billing Account Administrator permissions to bind roles/billing.admin on var.billing_account_id for the enforcer SA"
  type        = bool
  default     = false
}

variable "relax_project_drs_for_billing_pubsub" {
  description = <<-EOT
    Override constraints/iam.allowedPolicyMemberDomains on the project so Cloud Billing Budgets can grant
    roles/pubsub.publisher on the budget Pub/Sub topic to Google's global service account
    (billing-budget-alert@system.gserviceaccount.com). Required when the parent organization enforces
    Domain Restricted Sharing, unless the override is toggled manually via gcloud during budget creation.
  EOT
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Multi-Channel Alerting (Email & Slack / Webhook)
# ------------------------------------------------------------------------------
variable "alert_emails" {
  description = "List of up to 5 email addresses to receive Cloud Billing Budget notifications via Cloud Monitoring channels"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.alert_emails) <= 5
    error_message = "Cloud Billing Budgets support a maximum of 5 Cloud Monitoring notification channels. Provide at most 5 email addresses (use group aliases for larger lists)."
  }
}

variable "disable_default_iam_recipients" {
  description = "If true, disables sending budget emails to default Billing Account Admins and Users (relies on alert_emails and Pub/Sub; required when alert_emails is non-empty in cross-org billing setups)"
  type        = bool
  default     = true
}

variable "enable_slack_webhook" {
  description = "Enable rich Slack Block Kit notifications via Secret Manager and the Enforcer Cloud Function"
  type        = bool
  default     = false
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL (stored in Secret Manager). Leave empty to populate the secret version manually outside Terraform."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_channel_name" {
  description = "Display label for the target Slack channel in logs and context footers (e.g., #finops-alerts)"
  type        = string
  default     = "#finops-alerts"
}


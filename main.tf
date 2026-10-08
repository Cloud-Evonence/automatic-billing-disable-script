#main.tf

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0.0"
    }
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

# ──────────────────────────────────────────────────────────────
# 0) Param: handle Editor on Default Compute SA → keep | revoke
# ──────────────────────────────────────────────────────────────
variable "default_sa_editor_mode" {
  description = "How to handle roles/editor on Default Compute Engine SA: 'keep' or 'revoke'."
  type        = string
  validation {
    condition     = contains(["keep", "revoke"], var.default_sa_editor_mode)
    error_message = "Must be one of: keep, revoke."
  }
}

locals {
  keep_editor   = var.default_sa_editor_mode == "keep"
  revoke_editor = var.default_sa_editor_mode == "revoke"

  # Common label to apply wherever supported
  do_not_delete_lbl = {
    do-not-delete      = "true"
    guardrails         = "true"
    guardrails_enabled = "true"
  }

  budget_amounts = [for k, v in var.budgets : v.amount]
  min_budget     = min(local.budget_amounts...)
}

# ──────────────────────────────────────────────────────────────
# 1) Enable required APIs
# ──────────────────────────────────────────────────────────────
resource "google_project_service" "enable_services" {
  for_each = toset([
    "monitoring.googleapis.com",
    "cloudbilling.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "billingbudgets.googleapis.com",
    "parametermanager.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudscheduler.googleapis.com",
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# ──────────────────────────────────────────────────────────────
# 1a) Enable Cloud Billing Audit Logging for Project
# ──────────────────────────────────────────────────────────────
resource "google_project_iam_audit_config" "billing_audit_config" {
  project = var.project_id
  service = "cloudbilling.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }

  depends_on = [google_project_service.enable_services]
}

data "google_project" "project" {}

data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/script/function_source"
  output_path = "${path.module}/script/budget_alert_function.zip"
}

# ──────────────────────────────────────────────────────────────
# 1b) Default Compute SA + IAM bootstrap
# ──────────────────────────────────────────────────────────────
data "google_compute_default_service_account" "default" {
  project    = var.project_id
  depends_on = [google_project_service.enable_services]
}

locals {
  default_compute_sa = data.google_compute_default_service_account.default.email
}

# Keep permanently: roles/run.invoker (asked)
resource "google_project_iam_member" "default_sa_run_invoker" {
  project    = var.project_id
  role       = "roles/run.invoker"
  member     = "serviceAccount:${local.default_compute_sa}"
  depends_on = [google_project_service.enable_services]
}

# KEEP path: manage Editor via Terraform when mode == keep
resource "google_project_iam_member" "default_sa_editor_keep" {
  count      = local.keep_editor ? 1 : 0
  project    = var.project_id
  role       = "roles/editor"
  member     = "serviceAccount:${local.default_compute_sa}"
  depends_on = [google_project_service.enable_services]
}

# REVOKE path: grant early via gcloud (so bootstrap can proceed)…
resource "null_resource" "editor_grant_bootstrap" {
  count    = local.revoke_editor ? 1 : 0
  triggers = { requested_at = timestamp() }

  depends_on = [
    google_project_service.enable_services,
    data.google_compute_default_service_account.default
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOC
      set -euo pipefail
      gcloud projects add-iam-policy-binding "${var.project_id}" \
        --member="serviceAccount:${local.default_compute_sa}" \
        --role="roles/editor" --quiet
    EOC
  }
}

# …and revoke just before the apply completes
resource "null_resource" "editor_revoke" {
  count    = local.revoke_editor ? 1 : 0
  triggers = { requested_at = timestamp() }
  depends_on = [
    google_cloudfunctions2_function.budget_alert_function,
    google_billing_budget.monthly_budget,
    google_pubsub_subscription.budget_alert_subscription
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOC
      set -euo pipefail
      gcloud projects remove-iam-policy-binding "${var.project_id}" \
        --member="serviceAccount:${local.default_compute_sa}" \
        --role="roles/editor" --quiet || true
    EOC
  }
}

# Anchor to ensure revoke runs last if present
resource "null_resource" "finalize_editor_mode" {
  depends_on = [null_resource.editor_revoke]
}

# ──────────────────────────────────────────────────────────────
# 2) Pub/Sub for budget alerts
# ──────────────────────────────────────────────────────────────
resource "google_pubsub_topic" "budget_alert_topic" {
  name       = var.pubsub_topic_name
  labels     = local.do_not_delete_lbl
  depends_on = [google_project_service.enable_services]
}

resource "google_pubsub_subscription" "budget_alert_subscription" {
  name  = var.pubsub_subscription_name
  topic = google_pubsub_topic.budget_alert_topic.id
  # (Subscription labels are not universally supported; leaving off to avoid schema errors)
  depends_on = [google_project_service.enable_services]
}

resource "google_pubsub_topic_iam_member" "billing_pubsub_publisher" {
  topic  = google_pubsub_topic.budget_alert_topic.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:billing-budget-alert@system.gserviceaccount.com"
}

# ──────────────────────────────────────────────────────────────
# 3) Billing budget with automatic disable (Multiple)
# ──────────────────────────────────────────────────────────────
resource "google_billing_budget" "monthly_budget" {
  for_each        = var.budgets
  billing_account = var.billing_account_id
  display_name    = "${each.key} - Monthly Budget - Automatic Disabling"

  amount {
    specified_amount {
      currency_code = var.currency
      units         = floor(each.value.amount)
      nanos         = (each.value.amount - floor(each.value.amount)) * 1000000000
    }
  }

  budget_filter {
    projects               = ["projects/${data.google_project.project.number}"]
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  dynamic "threshold_rules" {
    for_each = each.value.thresholds
    content {
      threshold_percent = threshold_rules.value
    }
  }

  all_updates_rule {
    pubsub_topic                   = google_pubsub_topic.budget_alert_topic.id
    schema_version                 = "1.0"
    disable_default_iam_recipients = false
  }

  depends_on = [
    google_pubsub_topic.budget_alert_topic,
    google_project_service.enable_services
  ]
}

# ──────────────────────────────────────────────────────────────
# 3a) Hourly Cloud Scheduler for automated Budget syncing
# ──────────────────────────────────────────────────────────────
resource "google_cloud_scheduler_job" "hourly_budget_sync" {
  name        = "do-not-delete-hourly-budget-sync"
  description = "Hourly trigger to synchronize Cloud Billing Budget targets and state into Parameter Manager"
  schedule    = "0 * * * *"
  time_zone   = "UTC"

  pubsub_target {
    topic_name = google_pubsub_topic.budget_alert_topic.id
    data       = base64encode(jsonencode({
      action = "sync_budget_state"
      source = "cloud_scheduler"
    }))
  }

  depends_on = [
    google_pubsub_topic.budget_alert_topic,
    google_project_service.enable_services
  ]
}



# ──────────────────────────────────────────────────────────────
# 4) Cloud Function setup
# ──────────────────────────────────────────────────────────────
resource "google_service_account" "cloud_function_service_account" {
  account_id   = var.cloud_function_service_account_id
  display_name = var.cloud_function_service_account_display_name
  # (Service accounts don't support user labels)
  depends_on = [google_project_service.enable_services]
}

resource "google_parameter_manager_parameter" "billing_state_parameter" {
  parameter_id = var.billing_state_parameter_id
  labels       = local.do_not_delete_lbl
  depends_on   = [google_project_service.enable_services]
}

resource "google_parameter_manager_parameter_version" "billing_state_initial" {
  parameter            = google_parameter_manager_parameter.billing_state_parameter.id
  parameter_version_id = "1"
  parameter_data = jsonencode({
    active_limit = local.min_budget
    status       = "active"
    month        = ""
    limits       = local.budget_amounts
  })
  lifecycle {
    ignore_changes = [
      parameter_data
    ]
  }
}

resource "google_secret_manager_secret" "notification_config_secret" {
  secret_id = "do-not-delete-billing-notifications"
  labels    = local.do_not_delete_lbl
  replication {
    auto {}
  }
  depends_on = [google_project_service.enable_services]
}

resource "google_secret_manager_secret_version" "notification_config_initial" {
  secret = google_secret_manager_secret.notification_config_secret.id
  secret_data = jsonencode({
    google_chat_webhook_url = var.google_chat_webhook_url
    smtp_host               = var.smtp_host
    smtp_port               = var.smtp_port
    smtp_username           = var.smtp_username
    smtp_key                = var.smtp_key
    smtp_sender_email       = var.smtp_sender_email
    smtp_use_tls            = var.smtp_use_tls
  })
  lifecycle {
    ignore_changes = [
      secret_data
    ]
  }
}

resource "google_secret_manager_secret_iam_member" "cf_sa_secret_accessor" {
  secret_id = google_secret_manager_secret.notification_config_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_function_service_account.email}"
}

resource "google_project_iam_member" "cf_sa_parameter_accessor" {
  project    = var.project_id
  role       = "roles/parametermanager.parameterAccessor"
  member     = "serviceAccount:${google_service_account.cloud_function_service_account.email}"
  depends_on = [google_project_service.enable_services]
}

resource "google_project_iam_member" "cf_sa_parameter_version_manager" {
  project    = var.project_id
  role       = "roles/parametermanager.parameterVersionManager"
  member     = "serviceAccount:${google_service_account.cloud_function_service_account.email}"
  depends_on = [google_project_service.enable_services]
}

resource "google_project_iam_member" "cf_sa_logging_viewer" {
  project    = var.project_id
  role       = "roles/logging.viewer"
  member     = "serviceAccount:${google_service_account.cloud_function_service_account.email}"
  depends_on = [google_project_service.enable_services]
}

resource "google_project_iam_member" "billing_project_manager_binding" {
  project    = var.project_id
  role       = "roles/billing.projectManager"
  member     = "serviceAccount:${google_service_account.cloud_function_service_account.email}"
  depends_on = [google_project_service.enable_services]
}

# Real-time Log Sink: forward Billing re-attachment audit events directly to Pub/Sub
resource "google_logging_project_sink" "billing_reattached_sink" {
  name        = "do-not-delete-billing-reattached-sink"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.budget_alert_topic.id}"
  filter      = <<-EOT
    protoPayload.serviceName="cloudbilling.googleapis.com"
    AND (protoPayload.methodName:"UpdateProjectBillingInfo" OR protoPayload.methodName:"AssignResourceToBillingAccount")
    AND NOT protoPayload.authenticationInfo.principalEmail:"gserviceaccount.com"
  EOT

  unique_writer_identity = true
  depends_on             = [google_project_service.enable_services]
}

resource "google_pubsub_topic_iam_member" "sink_pubsub_publisher" {
  topic  = google_pubsub_topic.budget_alert_topic.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.billing_reattached_sink.writer_identity
}




resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "cloud_function_bucket" {
  name                        = "${var.cloud_function_bucket_prefix}-${random_id.bucket_suffix.hex}"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  labels                      = local.do_not_delete_lbl
  depends_on                  = [google_project_service.enable_services]
}

resource "google_storage_bucket_object" "function_archive" {
  name       = "budget_alert_function-${data.archive_file.function_zip.output_md5}.zip"
  bucket     = google_storage_bucket.cloud_function_bucket.name
  source     = data.archive_file.function_zip.output_path
  # Use object metadata for a comparable tag
  metadata   = local.do_not_delete_lbl
  depends_on = [google_project_service.enable_services, data.archive_file.function_zip]
}

resource "google_cloudfunctions2_function" "budget_alert_function" {
  name        = "do-not-delete-billing-disable-function"
  location    = var.region
  description = "Cloud Function to handle budget alert notifications"

  # Top-level labels (supported by CFv2) to carry do-not-delete
  labels = local.do_not_delete_lbl

  build_config {
    runtime     = var.cloud_function_runtime
    entry_point = var.cloud_function_entry_point
    source {
      storage_source {
        bucket = google_storage_bucket.cloud_function_bucket.name
        object = google_storage_bucket_object.function_archive.name
      }
    }
  }

  service_config {
    service_account_email          = google_service_account.cloud_function_service_account.email
    min_instance_count             = 0
    max_instance_count             = 1
    available_memory               = "${var.cloud_function_memory}M"
    timeout_seconds                = var.cloud_function_timeout
    ingress_settings               = "ALLOW_ALL"
    all_traffic_on_latest_revision = true

    environment_variables = {
      GCP_PROJECT              = var.project_id
      LOG_EXECUTION_ID         = "true"
      STATE_PARAMETER_ID       = google_parameter_manager_parameter.billing_state_parameter.parameter_id
      NOTIFICATION_SECRET_ID   = google_secret_manager_secret.notification_config_secret.secret_id
      NOTIFICATION_EMAILS      = join(",", local.target_emails)
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.budget_alert_topic.id
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
  }

  depends_on = [
    google_storage_bucket.cloud_function_bucket,
    google_storage_bucket_object.function_archive,
    google_project_service.enable_services,
    google_parameter_manager_parameter.billing_state_parameter,
    google_secret_manager_secret.notification_config_secret,
    google_project_iam_member.default_sa_editor_keep,
    google_project_iam_member.default_sa_run_invoker
  ]
}

# ──────────────────────────────────────────────────────────────
# 5) IAM‐based email channels + Detachment & Re-attachment Alerting
# ──────────────────────────────────────────────────────────────

# Fetch raw IAM policy JSON and Project metadata
data "google_project_iam_policy" "current" {
  project = var.project_id
}

locals {
  project_policy = jsondecode(data.google_project_iam_policy.current.policy_data)

  # Extract user emails strictly from Project Owner IAM bindings (roles/owner)
  iam_owner_emails = distinct(compact(flatten([
    for binding in lookup(local.project_policy, "bindings", []) : [
      for member in lookup(binding, "members", []) : (
        length(regexall("^user:(.+@.+)$", member)) > 0 ?
        regex("^user:(.+@.+)$", member)[0] : ""
      )
    ] if lookup(binding, "role", "") == "roles/owner"
  ])))

  # Use user-supplied var.notification_emails if provided; otherwise automatically fall back to Project Owners
  target_emails = length(var.notification_emails) > 0 ? distinct(var.notification_emails) : local.iam_owner_emails

}

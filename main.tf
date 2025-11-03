#main.tf

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
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
  keep_editor        = var.default_sa_editor_mode == "keep"
  revoke_editor      = var.default_sa_editor_mode == "revoke"

  # Common label to apply wherever supported
  do_not_delete_lbl  = { do-not-delete = "true" }
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
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
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
    command = <<-EOC
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
    google_monitoring_alert_policy.budget_warning_policy,
    google_pubsub_subscription.budget_alert_subscription
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOC
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
  name       = var.pubsub_subscription_name
  topic      = google_pubsub_topic.budget_alert_topic.id
  # (Subscription labels are not universally supported; leaving off to avoid schema errors)
  depends_on = [google_project_service.enable_services]
}

# ──────────────────────────────────────────────────────────────
# 3) Billing budget with automatic disable
# ──────────────────────────────────────────────────────────────
resource "google_billing_budget" "monthly_budget" {
  billing_account = var.billing_account_id
  display_name    = "Monthly Budget - Automatic Disabling"

  amount {
    specified_amount {
      currency_code = var.currency
      units         = var.budget_amount
    }
  }

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  threshold_rules { threshold_percent = 0.75 }
  threshold_rules { threshold_percent = 0.9  }
  threshold_rules { threshold_percent = 1.0  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alert_topic.id
    schema_version = "1.0"
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

resource "google_project_iam_binding" "billing_project_manager_binding" {
  project = var.project_id
  role    = "roles/billing.projectManager"
  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}",
  ]
  depends_on = [google_project_service.enable_services]
}

resource "google_project_iam_binding" "storage_admin_binding" {
  project = var.project_id
  role    = "roles/storage.admin"
  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}",
  ]
  depends_on = [google_project_service.enable_services]
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
  name    = "budget_alert_function.zip"
  bucket  = google_storage_bucket.cloud_function_bucket.name
  source  = "./script/budget_alert_function.zip"
  # Use object metadata for a comparable tag
  metadata = local.do_not_delete_lbl
  depends_on = [google_project_service.enable_services]
}

resource "google_cloudfunctions2_function" "budget_alert_function" {
  name        = "billing-disable-function"
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
      GCP_PROJECT = var.project_id
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.budget_alert_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_storage_bucket.cloud_function_bucket,
    google_storage_bucket_object.function_archive,
    google_project_service.enable_services
  ]
}

# ──────────────────────────────────────────────────────────────
# 5) IAM‐based email channels + 100% budget‐hit alerting
# ──────────────────────────────────────────────────────────────

# Fetch raw IAM policy JSON
data "google_project_iam_policy" "current" {
  project = var.project_id
}

locals {
  project_policy = jsondecode(data.google_project_iam_policy.current.policy_data)

  billing_admins = flatten([
    for b in local.project_policy.bindings :
    b.members if b.role == "roles/billing.admin"
  ])

  project_owners = flatten([
    for b in local.project_policy.bindings :
    b.members if b.role == "roles/owner"
  ])

  # Combine, keep only user principals, strip the "user:" prefix
  notification_emails = distinct([
    for p in concat(local.billing_admins, local.project_owners) :
    replace(p, "user:", "")
    if startswith(p, "user:")
  ])
}

# One email channel per extracted principal
resource "google_monitoring_notification_channel" "email" {
  for_each     = toset(local.notification_emails)
  display_name = "Budget Alert → ${each.key}"
  type         = "email"
  labels = {
    email_address = each.key
  }
  # Some Monitoring resources support user_labels; notification_channel does in API,
  # but provider support can vary. If supported in your provider version, uncomment:
  # user_labels = local.do_not_delete_lbl
  depends_on = [google_project_service.enable_services]
}

# Log‐based metric for the exact 100% warning
resource "google_logging_metric" "budget_warning_100pct" {
  name        = "budget_warning_100pct"
  description = "Count of Cloud Function logs at 100% spend warning"
  filter = <<-EOT
    resource.type="cloud_run_revision"
    AND
    textPayload:"WARNING: You have reached 100% of your budget. Your project will be detached from the billing account imminently if spending continues."
  EOT
  # (Logging metric doesn't support user labels)
  depends_on = [google_project_service.enable_services]
}

# Alert Policy fires immediately when metric > 0
resource "google_monitoring_alert_policy" "budget_warning_policy" {
  display_name = "Budget Hit 100% Warning"
  combiner     = "OR"
  severity     = "CRITICAL"

  # Add user labels here
  user_labels = local.do_not_delete_lbl

  # Condition for Gen2 Functions (runs on Cloud Run)
  conditions {
    display_name = "100% Budget Warning (Cloud Run)"
    condition_threshold {
      filter = <<-EOT
      resource.type="cloud_run_revision"
      AND
        metric.type="logging.googleapis.com/user/budget_warning_100pct"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  notification_channels = [
    for ch in google_monitoring_notification_channel.email : ch.id
  ]
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOD

# 🚨 Action Required: Project Billing Detached (Budget at 100%) 🚨

Hello Team,

Your Google Cloud project **`$${PROJECT_ID}`** has reached **100%** of its allocated monthly budget. As a result, **billing has been automatically detached**.

Please follow the steps below using the `reattach-billing.sh` script to safely restore services. This script is designed to re-link the billing account *and* prevent the automation from immediately detaching it again.

---

## 📋 Prerequisites

Before you begin, please ensure you have the following:

1.  **Script Access:** You must have the `reattach-billing.sh` script on your local machine.
2.  **Billing Account ID:** You will need the **Billing Account ID** (e.g., `0123-4567-8901`) you wish to re-attach.
3.  **Required IAM Permissions:** Your user account must have:
    * `roles/billing.projectManager` on the **Project** (`$${PROJECT_ID}`).
    * `roles/billing.user` on the **target Billing Account**.
4.  **CLI Setup:** Your Google Cloud SDK must be installed and authenticated:
    ```bash
    gcloud auth login
    gcloud config set project $${PROJECT_ID}
    ```

---

## 🔧 Rollback Steps (Using the Script)

1.  **Make the Script Executable**
    (You only need to do this once)
    ```bash
    chmod +x reattach-billing.sh
    ```

2.  **Run the Script**
    This command re-attaches billing non-interactively.
    
    > **Note:** Replace with your actual Billing Account ID when prompted. The `--skip-terraform` flag is recommended during this initial fix.

    ```bash
    ./reattach-billing.sh --skip-terraform
    ```

3.  **Verify the Output**
    The script will print the final billing state. Please **confirm that the output shows `True`**:
    ```text
    Billing Enabled: True
    ```

---

## ⚠️ Next Steps: Prevent Recurrence

Once billing is restored, you must update the budget to prevent this from happening again.

1.  **Increase Budget Threshold:** Edit your budget threshold amount.
2.  **Re-deploy:** Please rerun the deployment script to apply your changes.
    ```bash
    ./deploy.sh
    ```

If you encounter any issues, please contact the Evonence Cloud Infrastructure team.

    EOD
  }
  depends_on = [
    google_project_service.enable_services,
    google_logging_metric.budget_warning_100pct
  ]
}

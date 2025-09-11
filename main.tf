# main.tf

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
# 1) Enable required APIs
# ──────────────────────────────────────────────────────────────
resource "google_project_service" "enable_services" {
  for_each = toset([
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
# 2) Pub/Sub for budget alerts
# ──────────────────────────────────────────────────────────────
resource "google_pubsub_topic" "budget_alert_topic" {
  name = var.pubsub_topic_name
}

resource "google_pubsub_subscription" "budget_alert_subscription" {
  name  = var.pubsub_subscription_name
  topic = google_pubsub_topic.budget_alert_topic.id
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

  depends_on = [google_pubsub_topic.budget_alert_topic]
}

# ──────────────────────────────────────────────────────────────
# 4) Cloud Function setup
# ──────────────────────────────────────────────────────────────
resource "google_service_account" "cloud_function_service_account" {
  account_id   = var.cloud_function_service_account_id
  display_name = var.cloud_function_service_account_display_name
}

resource "google_project_iam_binding" "billing_project_manager_binding" {
  project = var.project_id
  role    = "roles/billing.projectManager"
  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}",
  ]
}

resource "google_project_iam_binding" "storage_admin_binding" {
  project = var.project_id
  role    = "roles/storage.admin"
  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}",
  ]
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "cloud_function_bucket" {
  name          = "${var.cloud_function_bucket_prefix}-${random_id.bucket_suffix.hex}"
  location      = var.region
  storage_class = "STANDARD"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_object" "function_archive" {
  name   = "budget_alert_function.zip"
  bucket = google_storage_bucket.cloud_function_bucket.name
  source = "./script/budget_alert_function.zip"
}

resource "google_cloudfunctions2_function" "budget_alert_function" {
  name        = "billing-disable-function"
  location    = var.region
  description = "Cloud Function to handle budget alert notifications"

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
}

# Alert Policy fires immediately when metric > 0
resource "google_monitoring_alert_policy" "budget_warning_policy" {
  display_name = "Budget Hit 100% Warning"
  combiner     = "OR"
  severity     = "CRITICAL"

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
# 🚨 Action Required: Project Has Hit 100% of Its Monthly Budget

Hello Team,

Your Google Cloud project has reached **100%** of its allocated monthly budget. Billing will be detached from the project imminently if no action is taken. Please follow the prerequisites and rollback steps below to restore billing and prevent service interruption.

---

## 📋 Prerequisites

1. **Billing Account ID**  
   You will need the Billing Account ID you wish to link

2. **Required IAM Permissions**  
- **Owner** or **Billing Admin** on the project  
- **Billing Account User** on the target billing account  

3. **gcloud CLI Setup**  
Ensure you have the Google Cloud SDK installed and are authenticated:

```bash
gcloud auth login
gcloud config set project **`$${PROJECT_ID}`**
```

## 🔧 Rollback Steps
1. Re-attach the Billing Account

```bash
gcloud beta billing projects link **`$${PROJECT_ID}`** \
  --billing-account=**Billing Account ID**  
```
This will immediately re-enable billing for your project.

2. Delete the Cloud Function

```bash
gcloud functions delete billing-disable-function \
```
Remove the function that auto-detaches billing so it doesn't immediately fire again.

3. Verify Billing Status

```bash
gcloud beta billing projects describe **`$${PROJECT_ID}`** \
  --format="value(billingEnabled)"
```
Should return TRUE.

4. Tear Down Terraform-Managed Resources

```bash
terraform destroy -auto-approve
```
Clean up any remaining infra before redeploying with updated thresholds.

5. Increase Budget Threshold & Re-deploy
  - Edit your Terraform google_billing_budget.threshold_rules to raise the critical rule above 100%.

If you encounter any issues or need further assistance, please reply to this email or contact the Cloud Engineering team.

Thank you for your prompt attention to this matter.
    EOD
  }
}

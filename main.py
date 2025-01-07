# main.tf

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable Required APIs
resource "google_project_service" "enable_services" {
  for_each = toset([
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudfunctions.googleapis.com",
    "logging.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com"
  ])
  project  = var.project_id
  service  = each.key
  disable_on_destroy = false
}

# Create Pub/Sub Topic
resource "google_pubsub_topic" "budget_alert_topic" {
  name = var.pubsub_topic_name
}

# Create Pub/Sub Subscription
resource "google_pubsub_subscription" "budget_alert_subscription" {
  name  = var.pubsub_subscription_name
  topic = google_pubsub_topic.budget_alert_topic.id
}

# Budget Definition
resource "google_billing_budget" "monthly_budget" {
  billing_account = var.billing_account_id

  display_name = "Monthly Budget - Automatic Disabling"

  # Budget Amount
  amount {
    specified_amount {
      currency_code = "USD"
      units         = 100 # Target amount in specified currency
    }
  }

  # Budget Filters - Optional
  budget_filter {
    projects = ["projects/${var.project_id}"] # Filter budget to specific project(s) if needed
    credit_types_treatment = "EXCLUDE_ALL_CREDITS" # Exclude discounts, promotions, and credits
  }

  # Threshold Rules
  threshold_rules {
    threshold_percent = 0.5 # 50%
  }

  threshold_rules {
    threshold_percent = 0.9 # 90%
  }

  threshold_rules {
    threshold_percent = 1.0 # 100%
  }

  # Notifications via Pub/Sub
  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alert_topic.id
    schema_version = "1.0"
  }

  depends_on = [
    google_pubsub_topic.budget_alert_topic
  ]
}

# Service Account for Cloud Function
resource "google_service_account" "cloud_function_service_account" {
  account_id   = "billing-disable-function-sa"
  display_name = "Service Account for Billing Disable Function"
}

# Bind Billing Project Manager Role to Service Account
resource "google_project_iam_binding" "billing_project_manager_binding" {
  project = var.project_id
  role    = "roles/viewer"

  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}"
  ]
}

# Cloud Storage Bucket for Cloud Function
resource "google_storage_bucket" "cloud_function_bucket" {
  name          = var.cloud_function_bucket_name
  location      = var.region
  force_destroy = true
}

resource "google_storage_bucket_object" "function_archive" {
  name   = "budget_alert_function.zip"
  bucket = google_storage_bucket.cloud_function_bucket.name
  source = "/home/utkarsh_pandey/automatic-billing-disable/budget_pub_run/budget_alert_function.zip" # Replace with the correct local file path
}

# Cloud Function
resource "google_cloudfunctions_function" "budget_alert_function" {
  name        = "billing-disable-function"
  description = "Cloud Function to handle budget alert notifications"
  runtime     = var.cloud_function_runtime
  available_memory_mb = var.cloud_function_memory
  timeout     = var.cloud_function_timeout

  service_account_email = google_service_account.cloud_function_service_account.email

  source_archive_bucket = google_storage_bucket.cloud_function_bucket.name
  source_archive_object = google_storage_bucket_object.function_archive.name
  entry_point           = var.cloud_function_entry_point

  # Define Pub/Sub trigger
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.budget_alert_topic.id
  }

  environment_variables = {
    GCP_PROJECT = var.project_id
  }

  depends_on = [
    google_storage_bucket.cloud_function_bucket,
    google_storage_bucket_object.function_archive,
  ]
}


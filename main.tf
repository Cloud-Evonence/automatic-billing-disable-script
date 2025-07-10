// main.tf

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

# Enable Required APIs
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

# resource "random_id" "default" {
#   byte_length = 8
# }

# resource "google_storage_bucket" "default" {
#   name     = "${random_id.default.hex}-terraform-remote-backend"
#   location = "US"

#   force_destroy               = true
#   public_access_prevention    = "enforced"
#   uniform_bucket_level_access = true

#   versioning {
#     enabled = true
#   }
# }

# resource "local_file" "default" {
#   file_permission = "0644"
#   filename        = "${path.module}/backend.tf"

#   # You can store the template in a file and use the templatefile function for
#   # more modularity, if you prefer, instead of storing the template inline as
#   # we do here.
#   content = <<-EOT
#   terraform {
#     backend "gcs" {
#       bucket = "${google_storage_bucket.default.name}"
#     }
#   }
#   EOT
# }

# Pub/Sub topic & subscription for budget alerts
resource "google_pubsub_topic" "budget_alert_topic" {
  name = var.pubsub_topic_name
}

resource "google_pubsub_subscription" "budget_alert_subscription" {
  name  = var.pubsub_subscription_name
  topic = google_pubsub_topic.budget_alert_topic.id
}

# Billing budget
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

  threshold_rules {
    threshold_percent = 0.75
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alert_topic.id
    schema_version = "1.0"
  }

  depends_on = [
    google_pubsub_topic.budget_alert_topic,
  ]
}

# Service account for the function
resource "google_service_account" "cloud_function_service_account" {
  account_id   = var.cloud_function_service_account_id
  display_name = var.cloud_function_service_account_display_name
}

# Grant it billing.projectManager 
resource "google_project_iam_binding" "billing_project_manager_binding" {
  project = var.project_id
  role    = "roles/billing.projectManager"
  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}",
  ]
}

# Grant it  storage.admin roles
resource "google_project_iam_binding" "storage_admin_binding" {
  project = var.project_id
  role    =  "roles/storage.admin"
  members = [
    "serviceAccount:${google_service_account.cloud_function_service_account.email}",
  ]
}

# Bucket to stage function ZIP
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "cloud_function_bucket" {
  name          = "${var.cloud_function_bucket_prefix}-${random_id.bucket_suffix.hex}"
  location      = var.region
  storage_class = "STANDARD"
}

resource "google_storage_bucket_object" "function_archive" {
  name   = "budget_alert_function.zip"
  bucket = google_storage_bucket.cloud_function_bucket.name
  source = "./script/budget_alert_function.zip"
}

# Gen 2 Cloud Function
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

# variables.tf

variable "billing_account_id" {
  description = "Billing account ID associated with the budget."
}

variable "pubsub_topic_name" {
  default     = "billing-disable-topic"
  description = "The name of the Pub/Sub topic for budget alerts."
}

variable "pubsub_subscription_name" {
  default     = "billing-disable-subscription"
  description = "The name of the Pub/Sub subscription for budget alerts."
}

variable "project_id" {
  description = "The Google Cloud Project ID."
}

variable "region" {
  description = "The GCP Region for resources."
  default     = "us-central1"
}

variable "cloud_function_bucket_name" {
  description = "The name of the Cloud Storage bucket to store the Cloud Function code."
  default     = null
}

variable "cloud_function_runtime" {
  description = "Runtime for the Cloud Function."
  default     = "python311"
}

variable "cloud_function_entry_point" {
  description = "Entry point of the Cloud Function (name of the Python function)."
  default     = "handle_budget_alert"
}

variable "cloud_function_memory" {
  description = "Memory allocation for the Cloud Function in MB."
  default     = 256
}

variable "cloud_function_timeout" {
  description = "Timeout for the Cloud Function in seconds."
  default     = 60
}

variable "cloud_function_service_account_id" {
  description = "Account ID for the Cloud Function's service account."
  default     = "billing-disable-function-sa"
}

variable "cloud_function_service_account_display_name" {
  description = "Display name for the Cloud Function's service account."
  default     = "Service Account for Billing Disable Function"
}

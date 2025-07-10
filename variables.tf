// variables.tf

variable "project_id" {
  description = "The Google Cloud Project ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account ID associated with the budget."
  type        = string
}

variable "budget_amount" {
  description = "Target budget amount (whole USD units)."
  type        = number
}

variable "currency" {
  description = "Currency code for the budget amount, e.g. USD."
  type        = string
}

variable "region" {
  description = "The GCP region for resources."
  type        = string
  default     = "us-central1"
}

variable "pubsub_topic_name" {
  description = "Name of the Pub/Sub topic for budget alerts."
  type        = string
  default     = "billing-disable-topic"
}

variable "pubsub_subscription_name" {
  description = "Name of the Pub/Sub subscription for budget alerts."
  type        = string
  default     = "billing-disable-subscription"
}

variable "cloud_function_bucket_prefix" {
  description = "Prefix for the Cloud Storage bucket name."
  type        = string
  default     = "billing-disable-cloud-function"
}

variable "cloud_function_runtime" {
  description = "Runtime for the Gen2 Cloud Function."
  type        = string
  default     = "python311"
}

variable "cloud_function_entry_point" {
  description = "Name of the function in your code to invoke."
  type        = string
  default     = "stop_billing"
}

variable "cloud_function_memory" {
  description = "Memory allocation for the function (in MB)."
  type        = number
  default     = 256
}

variable "cloud_function_timeout" {
  description = "Timeout for the function (in seconds)."
  type        = number
  default     = 60
}

variable "cloud_function_service_account_id" {
  description = "Account ID for the function's service account."
  type        = string
  default     = "billing-disable-function-sa"
}

variable "cloud_function_service_account_display_name" {
  description = "Display name for the function's service account."
  type        = string
  default     = "Service Account for Billing Disable Function"
}

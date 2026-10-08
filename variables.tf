// variables.tf

variable "project_id" {
  description = "The Google Cloud Project ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account ID associated with the budget."
  type        = string
}

variable "budgets" {
  description = "A map of budget configurations, each with an amount and list of thresholds."
  type = map(object({
    amount     = number
    thresholds = list(number)
  }))
}

variable "currency" {
  description = "Currency code for the budget amount (e.g., USD, INR, EUR, GBP, CAD, AUD)."
  type        = string
  default     = "USD"
  validation {
    condition     = can(regex("^[A-Za-z]{3}$", var.currency))
    error_message = "Currency must be a 3-letter uppercase ISO currency code (e.g., USD, INR, EUR, GBP)."
  }
}

variable "billing_state_parameter_id" {
  description = "Name of the Parameter Manager parameter for billing state."
  type        = string
  default     = "do-not-delete-billing-state"
}

variable "region" {
  description = "The GCP region for resources."
  type        = string
  default     = "us-central1"
}

variable "pubsub_topic_name" {
  description = "Name of the Pub/Sub topic for budget alerts."
  type        = string
  default     = "do-not-delete-billing-topic"
}

variable "pubsub_subscription_name" {
  description = "Name of the Pub/Sub subscription for budget alerts."
  type        = string
  default     = "do-not-delete-billing-sub"
}

variable "cloud_function_bucket_prefix" {
  description = "Prefix for the Cloud Storage bucket name."
  type        = string
  default     = "do-not-delete-billing-cf"
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
  default     = 540
}

variable "cloud_function_service_account_id" {
  description = "Account ID for the function's service account."
  type        = string
  default     = "do-not-delete-billing-sa"
}

variable "notification_emails" {
  description = "List of email addresses for budget alert notifications. If empty, emails will be extracted automatically strictly from Project Owners."
  type        = list(string)
  default     = []
}

variable "existing_notification_channel_ids" {
  description = "List of pre-existing Notification Channel resource IDs in GCP Monitoring. Takes 1st priority if available."
  type        = list(string)
  default     = []
}

variable "cloud_function_service_account_display_name" {
  description = "Display name for the function's service account."
  type        = string
  default     = "Service Account for Billing Disable Function"
}

variable "google_chat_webhook_url" {
  description = "Google Chat Space Webhook URL for direct notifications from Cloud Run (optional)."
  type        = string
  default     = ""
}

variable "smtp_host" {
  description = "SMTP Server hostname (e.g., smtp.gmail.com or smtp.sendgrid.net)."
  type        = string
  default     = "smtp.gmail.com"
}

variable "smtp_port" {
  description = "SMTP Server port (e.g., 587 or 465)."
  type        = number
  default     = 587
}

variable "smtp_username" {
  description = "SMTP username / email login."
  type        = string
  default     = ""
}

variable "smtp_key" {
  description = "Google Workspace / Gmail App Password or SMTP Secret Key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_sender_email" {
  description = "Sender email address for SMTP (e.g., alerts@yourcompany.com)."
  type        = string
  default     = ""
}

variable "smtp_use_tls" {
  description = "Whether to use STARTTLS for SMTP."
  type        = bool
  default     = true
}

# terraform.tfvars

billing_account_id       = "012E6E-8A3079-9A6E8B"
project_id               = "experiments-playground-436812"
region                   = "us-central1"
pubsub_topic_name        = "billing-disable-topic"
pubsub_subscription_name = "billing-disable-subscription"
cloud_function_bucket_name = "billing-disable-cloud-function-bucket"
cloud_function_runtime     = "python311"
cloud_function_entry_point = "stop_billing"
cloud_function_memory      = 256
cloud_function_timeout     = 60
cloud_function_service_account_id         = "billing-disable-function-sa"
cloud_function_service_account_display_name = "Service Account for Billing Disable Function"
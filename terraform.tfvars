# terraform.tfvars

billing_account_id       = "XXXXX-XXXXX-XXXXX"
project_id               = "project_id"
region                   = "us-central1"
pubsub_topic_name        = "billing-disable-topic"
pubsub_subscription_name = "billing-disable-subscription"
cloud_function_bucket_name = "billing-disable-cloud-function-${timestamp()}-${random_id.bucket_suffix.hex}"
cloud_function_runtime     = "python311"
cloud_function_entry_point = "stop_billing"
cloud_function_memory      = 256
cloud_function_timeout     = 60
cloud_function_service_account_id         = "billing-disable-function-sa"
cloud_function_service_account_display_name = "Service Account for Billing Disable Function"

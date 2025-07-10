#backend.tf

terraform {
  backend "gcs" {
    prefix = "terraform/state"
}
}

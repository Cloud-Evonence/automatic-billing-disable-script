#!/usr/bin/env bash
set -euo pipefail

# —— 0) Discover PROJECT from gcloud config —— 
PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "$PROJECT" ]]; then
  echo "❌ No default project set. Run 'gcloud config set project <ID>' first." >&2
  exit 1
fi

# —— 1) Export for Terraform —— 
export TF_VAR_project_id="$PROJECT"

# —— 2) Enabling APIs —— 
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com cloudbilling.googleapis.com --project "$PROJECT"

# —— 3) Other defaults —— 
: "${TF_VAR_region:=us-central1}"
BUCKET="terraform-state-billing-detach-${PROJECT}"

# —— 4) Ensure the bucket exists —— 
if ! gsutil ls -b "gs://$BUCKET" >/dev/null 2>&1; then
  echo "🚀 Creating bucket gs://$BUCKET in $TF_VAR_region…"
  gsutil mb -p "$PROJECT" -l "$TF_VAR_region" "gs://$BUCKET"
  gsutil versioning set on "gs://$BUCKET"
else
  echo "✅ Bucket gs://$BUCKET already exists"
fi 

# —— 5) Init & Apply Terraform —— 
terraform init \
  -backend-config="bucket=$BUCKET" \
  -backend-config="prefix=terraform/state"

terraform apply --auto-approve

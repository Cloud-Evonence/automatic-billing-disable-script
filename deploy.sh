#!/usr/bin/env bash
set -euo pipefail

# —— Configuration —— 
PROJECT="${PROJECT}"
REGION="us-central1"
BUCKET="terraform-state-${PROJECT}"   # or any fixed name you like

# —— 1) Ensure the bucket exists —— 
if ! gsutil ls -b gs://"$BUCKET" >/dev/null 2>&1; then
  echo "🚀 Creating bucket gs://$BUCKET in $REGION (project $PROJECT)…"
  gsutil mb -p "$PROJECT" -l "$REGION" gs://"$BUCKET"
  echo "🔒 Enabling uniform ACLs + public-access prevention…"
  gsutil uniformbucketlevelaccess set on gs://"$BUCKET"
  gsutil iam ch allUsers:objectViewer gs://"$BUCKET" || true   # remove if you don't want public viewers
  echo "🗃️  Turning on versioning…"
  gsutil versioning set on gs://"$BUCKET"
else
  echo "✅ Bucket gs://$BUCKET already exists"
fi

# —— 2) Init Terraform with that backend —— 
terraform init \
  -backend-config="bucket=$BUCKET" \
  -backend-config="prefix=terraform/state" 

# —— 2) Terraform Apply —— 
terraform apply --auto-approve \

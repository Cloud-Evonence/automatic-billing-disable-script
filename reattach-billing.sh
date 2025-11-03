#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────────────
# Rollback script (no function deletion)
# Steps:
# 0) Remove roles/billing.projectManager from runtime SA (project-level)
# 1) Re-attach the Billing Account to the project
# 2) Verify billing status (should be TRUE)
# 3) Optional: terraform destroy
# ───────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage:
  ./rollback_billing_detach.sh \
    [-p <PROJECT_ID>] \
    [-b <BILLING_ACCOUNT_ID>] \
    [-s <RUNTIME_SA_EMAIL> (default: billing-ditach-sa@${PROJECT_ID}.iam.gserviceaccount.com)] \
    [--tf-dir <PATH> (default: current dir)] \
    [--skip-terraform]

Notes:
- If -p is omitted, the script uses 'gcloud config get-value project' or prompts.
- If -b is omitted, the script will prompt for a Billing Account ID.
- If -s is omitted, it defaults to billing-ditach-sa@${PROJECT_ID}.iam.gserviceaccount.com
EOF
}

PROJECT_ID="${PROJECT_ID:-}"            # allow env override
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-}"
RUNTIME_SA="${RUNTIME_SA:-}"
TF_DIR="."
SKIP_TERRAFORM="false"

# Parse args
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="$2"; shift 2 ;;
    -b|--billing-account) BILLING_ACCOUNT_ID="$2"; shift 2 ;;
    -s|--service-account) RUNTIME_SA="$2"; shift 2 ;;
    --tf-dir) TF_DIR="$2"; shift 2 ;;
    --skip-terraform) SKIP_TERRAFORM="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

# Resolve PROJECT_ID
if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID="$(gcloud config get-value project --quiet 2>/dev/null || true)"
fi
if [[ -z "${PROJECT_ID}" ]]; then
  read -r -p "Enter GCP PROJECT_ID: " PROJECT_ID
fi
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is required."; exit 1
fi

# Export for downstream tools
export PROJECT_ID

# Default runtime SA if not provided
if [[ -z "${RUNTIME_SA}" ]]; then
  RUNTIME_SA="billing-ditach-sa@${PROJECT_ID}.iam.gserviceaccount.com"
fi

# Prompt for Billing Account ID if missing
if [[ -z "${BILLING_ACCOUNT_ID}" ]]; then
  read -r -p "Enter Billing Account ID (e.g., 0123-4567-8901): " BILLING_ACCOUNT_ID
fi
if [[ -z "${BILLING_ACCOUNT_ID}" ]]; then
  echo "ERROR: Billing Account ID is required."; exit 1
fi

echo "───────────────────────────────────────────────────────────────"
echo "Rollback starting for project: ${PROJECT_ID}"
echo "Billing account to link     : ${BILLING_ACCOUNT_ID}"
echo "Runtime service account     : ${RUNTIME_SA}"
echo "Terraform dir               : ${TF_DIR}"
echo "Skip terraform destroy      : ${SKIP_TERRAFORM}"
echo "───────────────────────────────────────────────────────────────"

# Step 0: Remove roles/billing.projectManager from runtime SA (project-level)
echo "[0/3] Removing roles/billing.projectManager from ${RUNTIME_SA} on project ${PROJECT_ID} (if present)…"
set +e
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/billing.projectManager" \
  --quiet >/dev/null 2>&1
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  echo "✓ Removed (or not present) project-level roles/billing.projectManager from ${RUNTIME_SA}."
else
  echo "⚠️  Could not remove roles/billing.projectManager (may not be bound). Continuing…"
fi

# Step 1: Re-attach billing account
echo "[1/3] Linking billing account ${BILLING_ACCOUNT_ID} to project ${PROJECT_ID}…"
gcloud beta billing projects link "${PROJECT_ID}" \
  --billing-account="${BILLING_ACCOUNT_ID}" \
  --quiet
echo "✓ Billing re-attached."

# Step 2: Verify billing status
echo "[2/3] Verifying billing status…"
BILLING_ENABLED="$(gcloud beta billing projects describe "${PROJECT_ID}" --format="value(billingEnabled)")"
echo "Billing Enabled: ${BILLING_ENABLED}"
if [[ "${BILLING_ENABLED}" != "True" && "${BILLING_ENABLED}" != "TRUE" ]]; then
  echo "❌ Billing is NOT enabled for ${PROJECT_ID}. Please check permissions and billing account status."
  exit 2
fi
echo "✓ Billing is enabled."

# Step 3: Terraform destroy (optional)
if [[ "${SKIP_TERRAFORM}" == "true" ]]; then
  echo "[3/3] Skipping terraform destroy as requested."
else
  echo "[3/3] Running 'terraform destroy -auto-approve' in '${TF_DIR}'…"
  if ! command -v terraform >/dev/null 2>&1; then
    echo "⚠️  'terraform' not found in PATH. Skipping destroy."
  else
    if [[ -d "${TF_DIR}" ]]; then
      pushd "${TF_DIR}" >/dev/null
      set +e
      terraform destroy -auto-approve
      TF_RC=$?
      set -e
      popd >/dev/null
      if [[ $TF_RC -eq 0 ]]; then
        echo "✓ Terraform destroy complete."
      else
        echo "⚠️  Terraform destroy did not complete successfully (possibly no state). Review output above."
      fi
    else
      echo "⚠️  TF_DIR '${TF_DIR}' does not exist. Skipping terraform destroy."
    fi
  fi
fi

echo "───────────────────────────────────────────────────────────────"
echo "Rollback finished for project: ${PROJECT_ID}"
echo "Billing is enabled. (No function deletion performed.)"
echo "───────────────────────────────────────────────────────────────"

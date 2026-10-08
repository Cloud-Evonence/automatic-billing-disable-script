#!/usr/bin/env bash
set -euo pipefail

# —— Mitigate IPv6 DNS resolution issues (Happy Eyeballs / no route) ——
export GODEBUG=netdns=cgo

if [[ -f /etc/gai.conf ]]; then
  if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf && ! grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf; then
    echo "ℹ️  Configuring /etc/gai.conf to prioritize IPv4 over IPv6..."
    echo "precedence ::ffff:0:0/96 100" | sudo tee -a /etc/gai.conf >/dev/null 2>&1 || true
  fi
fi

if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "0"; then
  echo "ℹ️  Disabling IPv6 on network interfaces to prevent GCP API connection issues..."
  sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true
fi

# Check python availability
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "❌ ERROR: Python not found. Cannot configure threshold state." >&2
  exit 1
fi

# —— Parse arguments ——
NON_INTERACTIVE="false"
BILLING_ACCOUNT_ID=""
BUDGETS_FILE="budgets.tfvars.json"
PROJECT_ARG=""

usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  -p, --project PROJECT_ID    Specify GCP Project ID (will set default project in gcloud config)
  -n, --non-interactive       Run in non-interactive mode (requires budgets.tfvars.json and billing account set)
  -b, --billing-account ID    Specify Billing Account ID
  -c, --currency CODE         Specify currency code (default: USD)
  -f, --budgets-file FILE     Specify custom tfvars JSON file for budgets (default: budgets.tfvars.json)
  -h, --help                  Show this help message
EOF
}

CURRENCY_CODE="USD"
CURRENCY_FLAG_PASSED="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ARG="$2"; shift 2 ;;
    -n|--non-interactive) NON_INTERACTIVE="true"; shift ;;
    -b|--billing-account) BILLING_ACCOUNT_ID="$2"; shift 2 ;;
    -c|--currency) CURRENCY_CODE="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; CURRENCY_FLAG_PASSED="true"; shift 2 ;;
    -f|--budgets-file) BUDGETS_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# —— 0) Discover or Set PROJECT from gcloud config —— 
if [[ -n "$PROJECT_ARG" ]]; then
  echo "Setting default gcloud project to $PROJECT_ARG..."
  gcloud config set project "$PROJECT_ARG" --quiet
fi

PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "$PROJECT" ]]; then
  echo "❌ No default project set. Run 'gcloud config set project <ID>' or pass -p <ID> first." >&2
  exit 1
fi

export TF_VAR_project_id="$PROJECT"

# —— 0b) Validate IAM and Billing Access ——
echo "--------------------------------------------------------"
echo "Checking IAM permissions and Billing Account access..."
USER_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -n "$USER_ACCOUNT" ]]; then
  echo "Logged in as: $USER_ACCOUNT"
fi

# List project roles
echo "Querying project IAM roles for $USER_ACCOUNT on project $PROJECT..."
PROJECT_ROLES=$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten="bindings[].members" \
  --format="value(bindings.role)" \
  --filter="bindings.members:user:${USER_ACCOUNT}" 2>/dev/null || true)

if [[ -n "$PROJECT_ROLES" ]]; then
  echo "Detected Project Roles:"
  echo "$PROJECT_ROLES" | sed 's/^/  - /'
else
  echo "⚠️  Warning: Could not retrieve project IAM policy directly. Proceeding with checks..."
fi

# Check if Owner, Editor or all fine-grained roles are present
IS_OWNER_OR_EDITOR="false"
if [[ -n "$PROJECT_ROLES" ]]; then
  while read -r role; do
    if [[ "$role" == "roles/owner" || "$role" == "roles/editor" ]]; then
      IS_OWNER_OR_EDITOR="true"
    fi
  done <<< "$PROJECT_ROLES"
else
  # If we couldn't list roles, we proceed with caution
  IS_OWNER_OR_EDITOR="unknown"
fi

REQUIRED_FINE_GRAINED_ROLES=(
  "roles/resourcemanager.projectIamAdmin"
  "roles/serviceusage.serviceUsageAdmin"
  "roles/iam.serviceAccountAdmin"
  "roles/pubsub.admin"
  "roles/parametermanager.admin"
  "roles/cloudfunctions.developer"
  "roles/run.admin"
  "roles/storage.admin"
  "roles/monitoring.admin"
  "roles/logging.admin"
)

HAS_ALL_FINE_GRAINED="true"
MISSING_ROLES=()
if [[ "$IS_OWNER_OR_EDITOR" == "false" && -n "$PROJECT_ROLES" ]]; then
  for role in "${REQUIRED_FINE_GRAINED_ROLES[@]}"; do
    if ! echo "$PROJECT_ROLES" | grep -q "$role"; then
      HAS_ALL_FINE_GRAINED="false"
      MISSING_ROLES+=("$role")
    fi
  done
else
  HAS_ALL_FINE_GRAINED="false"
fi

if [[ "$IS_OWNER_OR_EDITOR" == "true" ]]; then
  echo "✅ Access Verified: Logged in user has Owner/Editor permissions."
elif [[ "$HAS_ALL_FINE_GRAINED" == "true" ]]; then
  echo "✅ Access Verified: Logged in user has all required fine-grained deployment roles (Least Privilege)."
elif [[ "$IS_OWNER_OR_EDITOR" == "unknown" ]]; then
  echo "ℹ️  Could not verify project roles directly. Ensure you have the necessary permissions."
else
  echo "⚠️  WARNING: Logged-in user is not Project Owner/Editor and is missing the following fine-grained roles:"
  for r in "${MISSING_ROLES[@]}"; do
    echo "  - $r"
  done
  echo "Deployment might fail if you do not have sufficient permissions to create resources."
  read -p "Do you want to proceed anyway? (y/n): " proceed_anyway
  if [[ ! "$proceed_anyway" =~ ^[Yy] ]]; then
    echo "❌ Deployment aborted."
    exit 1
  fi
fi

# Check Billing Account list
echo "Querying accessible Billing Accounts..."
ACCESSIBLE_BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name)" 2>/dev/null || true)

if [[ -n "$ACCESSIBLE_BILLING_ACCOUNTS" ]]; then
  echo "Detected Accessible Billing Accounts:"
  echo "$ACCESSIBLE_BILLING_ACCOUNTS" | sed 's/^/  - /'
else
  echo "⚠️  Warning: Could not list billing accounts. Ensure your account is a Billing Account Administrator or User."
fi

# Check if Default Compute SA has roles/run.invoker (required to route trigger events)
echo "Checking trigger permissions (roles/run.invoker)..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)" 2>/dev/null || true)
if [[ -n "$PROJECT_NUMBER" ]]; then
  DEFAULT_SA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  DEFAULT_SA_INVOKER=$(gcloud projects get-iam-policy "$PROJECT" \
    --flatten="bindings[].members" \
    --format="value(bindings.role)" \
    --filter="bindings.role:roles/run.invoker AND bindings.members:serviceAccount:${DEFAULT_SA_EMAIL}" 2>/dev/null || true)
  if [[ -n "$DEFAULT_SA_INVOKER" ]]; then
    echo "✅ Trigger Access: Default Compute SA already has 'roles/run.invoker' assigned."
  else
    echo "ℹ️  Trigger Access: Default Compute SA is missing 'roles/run.invoker'. Terraform will configure this binding during deployment."
  fi
else
  echo "⚠️  Warning: Could not fetch project number. Cannot verify Default Compute SA roles/run.invoker."
fi
echo "--------------------------------------------------------"

# —— 1) Collect Interactive Inputs if not non-interactive ——
if [[ "$NON_INTERACTIVE" == "false" ]]; then
  if [[ -f "$BUDGETS_FILE" ]]; then
    read -p "Found existing '$BUDGETS_FILE'. Use it? (y/n): " use_existing
    if [[ "$use_existing" =~ ^[Nn] ]]; then
      rm -f "$BUDGETS_FILE"
    fi
  fi

  # Ask for currency if NOT passed via CLI flag
  if [[ "$CURRENCY_FLAG_PASSED" == "false" ]]; then
    read -p "Enter Currency Code (e.g. USD, INR, EUR, GBP, AUD, CAD) [default: USD]: " input_currency
    if [[ -n "$input_currency" ]]; then
      CURRENCY_CODE="$(echo "$input_currency" | tr '[:lower:]' '[:upper:]')"
    fi
  else
    echo "ℹ️  Using currency code provided via flag: $CURRENCY_CODE"
  fi

  if [[ ! -f "$BUDGETS_FILE" ]]; then
    echo "--------------------------------------------------------"
    echo "Configuring billing detachment limits."
    read -p "How many budget limits do you want to configure? " num_limits
    cat <<EOF > "$BUDGETS_FILE"
{
  "budgets": {
EOF

    for ((i=1; i<=num_limits; i++)); do
      echo "--- Budget #$i Configuration ---"
      read -p "Amount ($CURRENCY_CODE): " amount
      
      read -p "How many alert triggers/thresholds do you want for Budget #$i? [default: 4]: " num_triggers
      if [[ -z "$num_triggers" ]]; then
        num_triggers=4
      fi

      echo "Default thresholds are 75%, 90%, 95%, 99% (expressed as 0.75, 0.9, 0.95, 0.99)."
      read -p "Enter custom thresholds as comma-separated decimals (e.g., 0.5,0.75,0.9,0.95,0.99,1.0) or press Enter for default: " custom_thresholds
      
      if [ -z "$custom_thresholds" ]; then
        thresholds="[0.75, 0.9, 0.95, 0.99]"
      else
        thresholds="[$custom_thresholds]"
      fi
      
      echo "    \"budget_$i\": {" >> "$BUDGETS_FILE"
      echo "      \"amount\": $amount," >> "$BUDGETS_FILE"
      echo "      \"thresholds\": $thresholds" >> "$BUDGETS_FILE"
      echo "    }" >> "$BUDGETS_FILE"
      
      if [ $i -lt $num_limits ]; then
        echo "    ," >> "$BUDGETS_FILE"
      fi
    done

    echo "  }," >> "$BUDGETS_FILE"

    echo "--------------------------------------------------------"
    echo "Configuring Alert Notification Email Recipients..."
    while true; do
      read -p "Enter notification recipient email address(es) (at least 1 required, comma-separated e.g. devops@company.com,lead@company.com): " custom_emails
      custom_emails=$(echo "$custom_emails" | xargs)
      if [ -n "$custom_emails" ]; then
        break
      fi
      echo "❌ ERROR: At least one recipient email address is required."
    done

    formatted_emails=$(echo "$custom_emails" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s -c .)

    echo "  \"notification_emails\": $formatted_emails" >> "$BUDGETS_FILE"
    echo "}" >> "$BUDGETS_FILE"

    echo "--------------------------------------------------------"
    echo "Configuring Email Alert Dispatcher..."
    read -s -p "Enter Google Workspace / SMTP App Password (press Enter to skip if already set in Secret Manager): " SMTP_SECRET_KEY
    echo ""
  fi

  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    read -p "Enter Billing Account ID (e.g. 0123-4567-8901): " billing_id
    BILLING_ACCOUNT_ID="$billing_id"
  fi
fi

if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
  # Try to read billing account ID from TF_VAR or env, or budgets file if available
  if [[ -n "${TF_VAR_billing_account_id:-}" ]]; then
    BILLING_ACCOUNT_ID="$TF_VAR_billing_account_id"
  elif [[ -f "$BUDGETS_FILE" ]]; then
    BILLING_ACCOUNT_ID=$(${PYTHON_BIN} -c "import json; data=json.load(open('${BUDGETS_FILE}')); print(data.get('billing_account_id', ''))" 2>/dev/null || true)
  fi

  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    echo "❌ ERROR: Billing Account ID is required. Pass with -b or set TF_VAR_billing_account_id." >&2
    exit 1
  fi
fi

# Validate Billing Account access
if [[ -n "${ACCESSIBLE_BILLING_ACCOUNTS:-}" ]]; then
  CLEAN_BILLING_ID=$(echo "$BILLING_ACCOUNT_ID" | tr -d '-')
  MATCH_FOUND="false"
  while read -r acct; do
    CLEAN_ACCT=$(echo "$acct" | tr -d '-')
    if [[ "$CLEAN_BILLING_ID" == "$CLEAN_ACCT" ]]; then
      MATCH_FOUND="true"
      break
    fi
  done <<< "$ACCESSIBLE_BILLING_ACCOUNTS"
  
  if [[ "$MATCH_FOUND" == "false" ]]; then
    echo "❌ ERROR: The selected billing account '$BILLING_ACCOUNT_ID' is not in your list of accessible billing accounts." >&2
    exit 1
  fi
fi

if [[ ! "$CURRENCY_CODE" =~ ^[A-Za-z]{3}$ ]]; then
  echo "❌ ERROR: Invalid 3-letter currency code '$CURRENCY_CODE'. Examples: USD, INR, EUR, GBP, AUD, CAD." >&2
  exit 1
fi

export TF_VAR_billing_account_id="$BILLING_ACCOUNT_ID"
export TF_VAR_currency="$CURRENCY_CODE"

# —— 2) Enabling APIs —— 
echo "Enabling core GCP service APIs..."
gcloud services enable \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudbilling.googleapis.com \
  parametermanager.googleapis.com \
  --project "$PROJECT" \
  --quiet

# —— 3) Other defaults —— 
: "${TF_VAR_region:=us-central1}"
BUCKET="terraform-state-billing-detach-${PROJECT}"

# —— 4) Ensure the GCS bucket exists —— 
if ! gsutil ls -b "gs://$BUCKET" >/dev/null 2>&1; then
  echo "🚀 Creating GCS bucket gs://$BUCKET in $TF_VAR_region…"
  gsutil mb -p "$PROJECT" -l "$TF_VAR_region" "gs://$BUCKET"
  gsutil versioning set on "gs://$BUCKET"
else
  echo "✅ GCS state bucket gs://$BUCKET already exists"
fi 

# —— 4b) Query Existing Notification Channels (1st Priority) ——
echo "Querying existing Monitoring Notification Channels in project $PROJECT..."
EXISTING_CHANNELS_JSON=$(gcloud monitoring channels list \
  --filter="type=email AND enabled=true" \
  --format="json" --project="$PROJECT" 2>/dev/null || true)

if [[ -n "$EXISTING_CHANNELS_JSON" && "$EXISTING_CHANNELS_JSON" != "[]" ]]; then
  EXISTING_CHANNEL_IDS=$(${PYTHON_BIN} -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ids = [ch['name'] for ch in data if ch.get('type') == 'email' and ch.get('enabled', True)]
    print(json.dumps(ids))
except Exception:
    print('[]')
" <<< "$EXISTING_CHANNELS_JSON" 2>/dev/null || echo "[]")

  if [[ "$EXISTING_CHANNEL_IDS" != "[]" && -n "$EXISTING_CHANNEL_IDS" ]]; then
    echo "✅ Detected pre-existing Email Notification Channels in project (1st Priority):"
    echo "$EXISTING_CHANNEL_IDS"
    export TF_VAR_existing_notification_channel_ids="$EXISTING_CHANNEL_IDS"
  fi
fi

# —— 5) Init, Validate & Apply Terraform —— 
echo "Setting up Terraform Google Cloud authentication token..."
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"

echo "Initializing Terraform..."
terraform init -reconfigure

echo "Validating Terraform configuration..."
terraform validate

echo "Applying Terraform configuration..."
terraform apply --auto-approve -var-file="$BUDGETS_FILE"

# —— 6) Initialize Parameter Manager billing state ——
if [[ -f "$BUDGETS_FILE" ]]; then
  INITIAL_JSON=$(${PYTHON_BIN} -c "
import json
data = json.load(open('${BUDGETS_FILE}'))
amounts = sorted([float(v['amount']) for v in data.get('budgets', {}).values()])
if not amounts:
    raise ValueError('No budget limits found in configuration.')
state = {
    'active_limit': amounts[0],
    'status': 'active',
    'month': '',
    'limits': amounts
}
print(json.dumps(state))
" 2>/dev/null || true)

  if [[ -n "${INITIAL_JSON}" ]]; then
    echo "Initializing Parameter Manager billing state with configured limits..."
    
    # Query parameter ID dynamically
    PARAMETER_ID=$(gcloud parametermanager parameters list --location="global" --project="$PROJECT" --format="value(name)" | grep "billing-state" | head -n 1 || true)
    if [[ -z "${PARAMETER_ID}" ]]; then
      PARAMETER_ID="do-not-delete-billing-state"
    else
      PARAMETER_ID=$(basename "${PARAMETER_ID}")
    fi
    
    # Push the initial state version if it doesn't exist
    TEMP_JSON_FILE=$(mktemp)
    echo -n "${INITIAL_JSON}" > "${TEMP_JSON_FILE}"
    if ! gcloud parametermanager parameters versions describe "1" --parameter="${PARAMETER_ID}" --location="global" --project="$PROJECT" >/dev/null 2>&1; then
      echo "Creating initial parameter version 1..."
      gcloud parametermanager parameters versions create "1" \
        --location="global" \
        --parameter="${PARAMETER_ID}" \
        --payload-data-from-file="${TEMP_JSON_FILE}" \
        --project="$PROJECT" >/dev/null
      echo "✓ Parameter Manager billing state initialized: ${INITIAL_JSON}"
    else
      echo "✓ Parameter Manager version 1 already exists. Skipping initialization."
    fi
    rm -f "${TEMP_JSON_FILE}"
  fi

  # —— 7) Store Notification Config securely in Secret Manager ——
  if [[ -n "${SMTP_SECRET_KEY:-}" ]]; then
    # Sanitize Google Workspace App Key by removing spaces
    CLEAN_SMTP_KEY=$(echo "${SMTP_SECRET_KEY}" | tr -d '[:space:]')
    echo "Updating Notification Secrets securely in Secret Manager..."
    SECRET_ID="do-not-delete-billing-notifications"
    TEMP_SECRET_FILE=$(mktemp)
    ${PYTHON_BIN} -c "
import os, json
payload = {
    'google_chat_webhook_url': os.getenv('GOOGLE_CHAT_WEBHOOK_URL', ''),
    'smtp_host': os.getenv('SMTP_HOST', 'smtp.gmail.com'),
    'smtp_port': int(os.getenv('SMTP_PORT', '587')),
    'smtp_username': os.getenv('SMTP_USERNAME', ''),
    'smtp_key': '${CLEAN_SMTP_KEY}',
    'smtp_sender_email': os.getenv('SMTP_SENDER_EMAIL', ''),
    'smtp_use_tls': True
}
print(json.dumps(payload))
" > "${TEMP_SECRET_FILE}"

    if gcloud secrets describe "${SECRET_ID}" --project="$PROJECT" >/dev/null 2>&1; then
      gcloud secrets versions add "${SECRET_ID}" \
        --data-file="${TEMP_SECRET_FILE}" \
        --project="$PROJECT" >/dev/null
      echo "✓ Notification credentials securely stored in Secret Manager."
    fi
    rm -f "${TEMP_SECRET_FILE}"
    SMTP_SECRET_KEY=""
  fi
fi

#!/usr/bin/env bash
# ==============================================================================
# Script: update_budget_value.sh
# Purpose: Dedicated script to update billing budget threshold values.
#          1. Checks existing Parameter Manager versions.
#          2. Computes and jumps to the next version to be created.
#          3. Interactively prompts the user for how many triggers and their costs.
#          4. Creates the new version payload in Parameter Manager.
#          5. Syncs budgets.tfvars.json and optionally applies Terraform budgets.
# ==============================================================================
set -euo pipefail

# Configuration & Defaults
DEFAULT_PROJECT="$(gcloud config get-value project 2>/dev/null || echo "")"
PROJECT_ID="${1:-$DEFAULT_PROJECT}"
PARAMETER_ID="do-not-delete-billing-state"
LOCATION="global"
BUDGETS_FILE="budgets.tfvars.json"

# Colors for UI Output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN} 🛠️  Dedicated Budget Threshold & Value Updater${NC}"
echo -e "${CYAN} Target Project: ${BOLD}${PROJECT_ID}${NC}"
echo -e "${CYAN}================================================================${NC}"

# ──────────────────────────────────────────────────────────────
# Step 1: Check First & Existing Parameter Manager Versions
# ──────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}🔍 Step 1: Checking Parameter Manager versions...${NC}"
VERSIONS_RAW=$(gcloud parametermanager parameters versions list \
    --parameter="${PARAMETER_ID}" \
    --location="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || true)

if [[ -z "${VERSIONS_RAW}" ]]; then
    echo -e "${YELLOW}ℹ️  No existing parameter versions found for '${PARAMETER_ID}'. Starting at v1.${NC}"
    LATEST_VERSION=0
    NEXT_VERSION=1
    CURRENT_PAYLOAD_JSON='{}'
else
    # Extract version numbers and sort numerically
    VERSION_NUMBERS=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            v_num=$(echo "$line" | awk -F'/' '{print $NF}')
            VERSION_NUMBERS+=("$v_num")
        fi
    done <<< "${VERSIONS_RAW}"

    SORTED_VERSIONS=($(printf '%s\n' "${VERSION_NUMBERS[@]}" | sort -n))
    FIRST_VERSION="${SORTED_VERSIONS[0]}"
    LATEST_VERSION="${SORTED_VERSIONS[-1]}"
    NEXT_VERSION=$((LATEST_VERSION + 1))

    echo -e "${GREEN}✓ Found ${#SORTED_VERSIONS[@]} existing version(s):${NC} $(printf 'v%s ' "${SORTED_VERSIONS[@]}")"
    echo -e "${GREEN}✓ First version in history:${NC} ${CYAN}v${FIRST_VERSION}${NC}"
    echo -e "${GREEN}✓ Current latest active version:${NC} ${CYAN}v${LATEST_VERSION}${NC}"
    echo -e "${BOLD}⏩ Next version that will be created:${NC} ${CYAN}v${NEXT_VERSION}${NC}"

    # Fetch and display current payload
    CURRENT_PAYLOAD_B64=$(gcloud parametermanager parameters versions describe \
        "projects/${PROJECT_ID}/locations/${LOCATION}/parameters/${PARAMETER_ID}/versions/${LATEST_VERSION}" \
        --view=FULL \
        --format="value(payload.data)" 2>/dev/null || echo "")

    if [[ -n "${CURRENT_PAYLOAD_B64}" ]]; then
        CURRENT_PAYLOAD_JSON=$(echo "${CURRENT_PAYLOAD_B64}" | base64 --decode)
        echo -e "\n${CYAN}Current Configuration in v${LATEST_VERSION}:${NC}"
        echo "${CURRENT_PAYLOAD_JSON}" | jq . 2>/dev/null || echo "${CURRENT_PAYLOAD_JSON}"
    else
        CURRENT_PAYLOAD_JSON='{}'
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 2: Prompt User for Number of Triggers & Cost Values
# ──────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}✏️  Step 2: Configure New Trigger Values & Costs${NC}"

# Ask for number of triggers
while true; do
    read -rp "How many triggers / budget limits do you want to configure? (e.g. 2): " NUM_TRIGGERS
    if [[ "$NUM_TRIGGERS" =~ ^[1-9][0-9]*$ ]]; then
        break
    fi
    echo -e "${RED}Please enter a valid positive integer (e.g. 1, 2, 3).${NC}"
done

USER_AMOUNTS=()
for ((i=1; i<=NUM_TRIGGERS; i++)); do
    while true; do
        read -rp "  Enter cost for Trigger #$i (USD, e.g. 50, 100): " AMT
        # Validate integer or float
        if [[ "$AMT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            USER_AMOUNTS+=("$AMT")
            break
        fi
        echo -e "${RED}  Please enter a valid numeric amount (e.g. 50 or 50.0).${NC}"
    done
done

# Sort user amounts numerically
SORTED_LIMITS_JSON=$(python3 -c "
import json, sys
raw = sys.argv[1:]
nums = sorted(list(set(float(x) for x in raw)))
print(json.dumps(nums))
" "${USER_AMOUNTS[@]}")

LOWEST_LIMIT=$(python3 -c "
import json, sys
limits = json.loads(sys.argv[1])
print(limits[0])
" "$SORTED_LIMITS_JSON")

echo -e "\n${GREEN}Configured Limits Array:${NC} ${CYAN}${SORTED_LIMITS_JSON}${NC}"

# Prompt for active limit (default to lowest)
read -rp "Enter initial Active Limit threshold [default: ${LOWEST_LIMIT}]: " INPUT_ACTIVE_LIMIT
ACTIVE_LIMIT="${INPUT_ACTIVE_LIMIT:-$LOWEST_LIMIT}"

# Prompt for status (default: active)
read -rp "Enter status [active/detached] [default: active]: " INPUT_STATUS
NEW_STATUS="${INPUT_STATUS:-active}"

# Default month
CURRENT_MONTH=$(date +%Y-%m)
read -rp "Enter month (YYYY-MM) [default: ${CURRENT_MONTH}]: " INPUT_MONTH
NEW_MONTH="${INPUT_MONTH:-$CURRENT_MONTH}"

# Construct JSON payload
NEW_PAYLOAD=$(jq -nc \
    --arg status "${NEW_STATUS}" \
    --argjson active_limit "${ACTIVE_LIMIT}" \
    --arg month "${NEW_MONTH}" \
    --argjson limits "${SORTED_LIMITS_JSON}" \
    '{active_limit: $active_limit, status: $status, limits: $limits, month: $month}')

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}Prepared Payload for Version v${NEXT_VERSION}:${NC}"
echo "${NEW_PAYLOAD}" | jq .
echo -e "${CYAN}================================================================${NC}"

read -rp "Proceed with creating Parameter Version v${NEXT_VERSION}? (y/n) [default: y]: " CONFIRM_CREATE
CONFIRM_CREATE="${CONFIRM_CREATE:-y}"
if [[ ! "$CONFIRM_CREATE" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Update canceled by user.${NC}"
    exit 0
fi

# ──────────────────────────────────────────────────────────────
# Step 3: Create Parameter Manager Version v${NEXT_VERSION}
# ──────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}🚀 Step 3: Creating Parameter Version v${NEXT_VERSION}...${NC}"
TEMP_PAYLOAD_FILE=$(mktemp)
echo -n "${NEW_PAYLOAD}" > "${TEMP_PAYLOAD_FILE}"

gcloud parametermanager parameters versions create "${NEXT_VERSION}" \
    --parameter="${PARAMETER_ID}" \
    --location="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --payload-data-from-file="${TEMP_PAYLOAD_FILE}"

rm -f "${TEMP_PAYLOAD_FILE}"
echo -e "${GREEN}✅ Version v${NEXT_VERSION} successfully created!${NC}"

# Clean up older versions (retain latest 3)
echo -e "\n${YELLOW}🧹 Cleaning up older parameter versions (retaining latest 3)...${NC}"
UPDATED_VERSIONS_RAW=$(gcloud parametermanager parameters versions list \
    --parameter="${PARAMETER_ID}" \
    --location="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || true)

ALL_VERSIONS=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        v_num=$(echo "$line" | awk -F'/' '{print $NF}')
        ALL_VERSIONS+=("$v_num")
    fi
done <<< "${UPDATED_VERSIONS_RAW}"

ALL_SORTED=($(printf '%s\n' "${ALL_VERSIONS[@]}" | sort -n))
TOTAL_VERSIONS=${#ALL_SORTED[@]}

if [[ $TOTAL_VERSIONS -gt 3 ]]; then
    DELETE_COUNT=$((TOTAL_VERSIONS - 3))
    for ((i=0; i<DELETE_COUNT; i++)); do
        OLD_VER="${ALL_SORTED[i]}"
        echo -e "Deleting old version: v${OLD_VER}..."
        gcloud parametermanager parameters versions delete "${OLD_VER}" \
            --parameter="${PARAMETER_ID}" \
            --location="${LOCATION}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
    done
fi

# ──────────────────────────────────────────────────────────────
# Step 4: Sync budgets.tfvars.json & Optionally Update Terraform
# ──────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}📝 Step 4: Synchronizing local ${BUDGETS_FILE}...${NC}"
if [[ -f "${BUDGETS_FILE}" ]]; then
    python3 -c "
import json, sys

budgets_file = '${BUDGETS_FILE}'
limits = json.loads('${SORTED_LIMITS_JSON}')

with open(budgets_file, 'r') as f:
    data = json.load(f)

# Reconstruct budgets dictionary based on triggers
new_budgets = {}
for idx, limit in enumerate(limits, 1):
    new_budgets[f'budget_{idx}'] = {
        'amount': int(limit) if limit.is_integer() else limit,
        'thresholds': [0.75, 0.9, 0.95, 0.99]
    }

data['budgets'] = new_budgets

with open(budgets_file, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(f'✓ Updated {budgets_file} with new triggers: {limits}')
"
    
    echo -e "\n${YELLOW}Sync with Cloud Billing Budgets via Terraform:${NC}"
    read -rp "Do you want to apply these new budget thresholds to Google Cloud via Terraform now? (y/n) [default: y]: " APPLY_TF
    APPLY_TF="${APPLY_TF:-y}"
    if [[ "$APPLY_TF" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Applying Terraform budget changes...${NC}"
        export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
        terraform apply --auto-approve -var-file="${BUDGETS_FILE}"
        echo -e "${GREEN}✅ Cloud Billing Budgets successfully synchronized!${NC}"
    else
        echo -e "${YELLOW}ℹ️  Skipped Terraform apply. You can apply anytime by running: terraform apply -var-file=${BUDGETS_FILE}${NC}"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 5: Verification & Summary
# ──────────────────────────────────────────────────────────────
echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN} 🎉 Parameter Manager State Successfully Updated to v${NEXT_VERSION}!${NC}"
echo -e "${GREEN}================================================================${NC}"

VERIFIED_PAYLOAD=$(gcloud parametermanager parameters versions describe \
    "projects/${PROJECT_ID}/locations/${LOCATION}/parameters/${PARAMETER_ID}/versions/${NEXT_VERSION}" \
    --view=FULL \
    --format="value(payload.data)" | base64 --decode)

echo "${VERIFIED_PAYLOAD}" | jq .

echo -e "\n${CYAN}Current Project Billing Status:${NC}"
gcloud billing projects describe "${PROJECT_ID}" --format="table(billingAccountName,billingEnabled)" 2>/dev/null || true
echo -e "\n${GREEN}Done!${NC}"

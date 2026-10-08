#!/usr/bin/env bash
# ==============================================================================
# Script: update_billing_state.sh
# Purpose: Dynamically fetch latest Parameter Manager version and update state
# Usage:
#   Interactive:      ./update_billing_state.sh [PROJECT_ID]
#   Non-interactive:  ./update_billing_state.sh [PROJECT_ID] --status active --limit 200.0 --limits "[50.0, 200.0]"
# ==============================================================================
set -euo pipefail

# Configuration Defaults
PROJECT_ID="${1:-our-philosophy-492900-c9}"
PARAMETER_ID="do-not-delete-billing-state"
LOCATION="global"

# Colors for output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Parse optional flags
CLI_STATUS=""
CLI_LIMIT=""
CLI_LIMITS=""
CLI_MONTH=""

shift $(( $# > 0 ? 1 : 0 )) || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--status) CLI_STATUS="$2"; shift 2 ;;
        -l|--limit)  CLI_LIMIT="$2"; shift 2 ;;
        --limits)    CLI_LIMITS="$2"; shift 2 ;;
        -m|--month)  CLI_MONTH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN} 🛠️  Parameter Manager State Manager: ${PROJECT_ID}${NC}"
echo -e "${CYAN}================================================================${NC}"

# 1. Fetch all versions dynamically
echo -e "\n${YELLOW}🔍 Step 1: Discovering existing parameter versions...${NC}"
VERSIONS_RAW=$(gcloud parametermanager parameters versions list \
    --parameter="${PARAMETER_ID}" \
    --location="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || true)

if [[ -z "${VERSIONS_RAW}" ]]; then
    echo -e "${RED}❌ No parameter versions found for parameter '${PARAMETER_ID}' in project '${PROJECT_ID}'.${NC}"
    exit 1
fi

# Extract version numbers and sort numerically
VERSION_NUMBERS=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        v_num=$(echo "$line" | awk -F'/' '{print $NF}')
        VERSION_NUMBERS+=("$v_num")
    fi
done <<< "${VERSIONS_RAW}"

LATEST_VERSION=$(printf '%s\n' "${VERSION_NUMBERS[@]}" | sort -n | tail -1)
NEXT_VERSION=$((LATEST_VERSION + 1))

echo -e "${GREEN}✓ Found latest version:${NC} ${CYAN}v${LATEST_VERSION}${NC}"
echo -e "${GREEN}✓ Next version ID to create:${NC} ${CYAN}v${NEXT_VERSION}${NC}"

# 2. Describe and decode the current version payload
echo -e "\n${YELLOW}📖 Step 2: Fetching current active payload from v${LATEST_VERSION}...${NC}"
CURRENT_PAYLOAD_B64=$(gcloud parametermanager parameters versions describe \
    "projects/${PROJECT_ID}/locations/${LOCATION}/parameters/${PARAMETER_ID}/versions/${LATEST_VERSION}" \
    --view=FULL \
    --format="value(payload.data)" 2>/dev/null || echo "")

if [[ -n "${CURRENT_PAYLOAD_B64}" ]]; then
    CURRENT_PAYLOAD_JSON=$(echo "${CURRENT_PAYLOAD_B64}" | base64 --decode)
    echo -e "${CYAN}Current Active Payload (v${LATEST_VERSION}):${NC}"
    echo "${CURRENT_PAYLOAD_JSON}" | jq . 2>/dev/null || echo "${CURRENT_PAYLOAD_JSON}"
else
    echo -e "${YELLOW}Warning: Could not decode payload from v${LATEST_VERSION}.${NC}"
    CURRENT_PAYLOAD_JSON='{"active_limit": 50.0, "status": "active", "limits": [50.0, 100.0], "month": "'$(date +%Y-%m)'"}'
fi

# 3. Determine new values
DEFAULT_MONTH=$(date +%Y-%m)
DEFAULT_LIMIT=$(echo "${CURRENT_PAYLOAD_JSON}" | jq -r '.active_limit // 50.0')
DEFAULT_LIMITS=$(echo "${CURRENT_PAYLOAD_JSON}" | jq -c '.limits // [50.0, 100.0]')

if [[ -n "${CLI_STATUS}" || -n "${CLI_LIMIT}" || -n "${CLI_LIMITS}" || -n "${CLI_MONTH}" ]]; then
    NEW_STATUS="${CLI_STATUS:-active}"
    NEW_LIMIT="${CLI_LIMIT:-${DEFAULT_LIMIT}}"
    NEW_LIMITS="${CLI_LIMITS:-${DEFAULT_LIMITS}}"
    NEW_MONTH="${CLI_MONTH:-${DEFAULT_MONTH}}"
else
    echo -e "\n${YELLOW}✏️  Step 3: Define New State Values${NC}"
    echo -e "(Press [Enter] to keep the default/recommended value shown in brackets)"

    read -rp "Enter Status [active/detached] [default: active]: " NEW_STATUS
    NEW_STATUS="${NEW_STATUS:-active}"

    read -rp "Enter Active Limit [default: ${DEFAULT_LIMIT}]: " NEW_LIMIT
    NEW_LIMIT="${NEW_LIMIT:-${DEFAULT_LIMIT}}"

    read -rp "Enter Limits Array [default: ${DEFAULT_LIMITS}]: " NEW_LIMITS
    NEW_LIMITS="${NEW_LIMITS:-${DEFAULT_LIMITS}}"

    read -rp "Enter Month (YYYY-MM) [default: ${DEFAULT_MONTH}]: " NEW_MONTH
    NEW_MONTH="${NEW_MONTH:-${DEFAULT_MONTH}}"
fi

# Construct new JSON payload
NEW_PAYLOAD=$(jq -nc \
    --arg status "${NEW_STATUS}" \
    --argjson active_limit "${NEW_LIMIT}" \
    --arg month "${NEW_MONTH}" \
    --argjson limits "${NEW_LIMITS}" \
    '{active_limit: $active_limit, status: $status, limits: $limits, month: $month}')

echo -e "\n${CYAN}Prepared New Payload for v${NEXT_VERSION}:${NC}"
echo "${NEW_PAYLOAD}" | jq .

# 4. Create the new Parameter Version
echo -e "\n${YELLOW}🚀 Step 4: Creating Parameter Version v${NEXT_VERSION}...${NC}"
gcloud parametermanager parameters versions create "${NEXT_VERSION}" \
    --parameter="${PARAMETER_ID}" \
    --location="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --payload-data="${NEW_PAYLOAD}"

echo -e "${GREEN}✅ Version v${NEXT_VERSION} successfully created!${NC}"

# 5. Clean up older versions (retain latest 3)
echo -e "\n${YELLOW}🧹 Step 5: Cleaning up older parameter versions (retaining latest 3)...${NC}"
ALL_VERSIONS_SORTED=($(printf '%s\n' "${VERSION_NUMBERS[@]}" | sort -n))
TOTAL_VERSIONS=${#ALL_VERSIONS_SORTED[@]}

if [[ $TOTAL_VERSIONS -gt 2 ]]; then
    DELETE_COUNT=$((TOTAL_VERSIONS - 2))
    for ((i=0; i<DELETE_COUNT; i++)); do
        OLD_VER="${ALL_VERSIONS_SORTED[i]}"
        echo -e "Deleting old version: v${OLD_VER}..."
        gcloud parametermanager parameters versions delete "${OLD_VER}" \
            --parameter="${PARAMETER_ID}" \
            --location="${LOCATION}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
    done
fi

# 6. Verification
echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN} 🎉 State Successfully Updated to v${NEXT_VERSION}!${NC}"
echo -e "${GREEN}================================================================${NC}"
gcloud parametermanager parameters versions describe \
    "projects/${PROJECT_ID}/locations/${LOCATION}/parameters/${PARAMETER_ID}/versions/${NEXT_VERSION}" \
    --view=FULL \
    --format="value(payload.data)" | base64 --decode | jq .

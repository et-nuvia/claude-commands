#!/usr/bin/env bash
set -euo pipefail

# Generic Secret Rotation Script
# Handles simple secret rotation (no coordination needed)
#
# Usage: ./scripts/rotate-generic.sh <bucket> [--dry-run]
#
# Examples:
#   ./scripts/rotate-generic.sh smtp
#   ./scripts/rotate-generic.sh api-keys --dry-run

BUCKET="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/colors.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"
# Resolved once; used in --domain args below. Fail fast if missing so the
# user gets a clear message instead of an opaque `--domain /api` failure.
_secrets_url="$(profile_env_get .secrets.url)"
if [[ -z "$_secrets_url" ]]; then
  echo "rotate-generic: .secrets.url not configured in profile" >&2
  exit 1
fi
SECRETS_API_URL="${_secrets_url}/api"

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

ENV=${ENVIRONMENT:-staging}
CONFIG=$(get_app_secrets_config)

APP_NAME=$(echo "$CONFIG" | jq -r '.app_name')
BACKEND=$(echo "$CONFIG" | jq -r '.secrets_backend')

echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "${BLUE}  Secret Rotation: ${BUCKET}${NC}"
echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "App: ${CYAN}${APP_NAME}${NC}"
echo "Environment: ${CYAN}${ENV}${NC}"
echo "Backend: ${CYAN}${BACKEND}${NC}"
echo ""

# This is a TEMPLATE script
# For your specific bucket, you'll need to customize:
#   1. How to generate new values
#   2. How to test new values
#   3. How to clean up old values

echo "${YELLOW}Step 1: Get current secret${NC}"

if [[ "$BACKEND" == "aws" ]]; then
    SECRET_ID="${APP_NAME}/${ENV}/${BUCKET}"
    CURRENT_SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_ID" \
        --query SecretString \
        --output text)
else
    CURRENT_SECRET=$(infisical secrets get DATA \
        --env "$ENV" \
        --path "/${BUCKET}" \
        --plain \
        --domain "${SECRETS_API_URL}")
fi

echo "Current secret:"
echo "$CURRENT_SECRET" | jq .

echo ""
echo "${YELLOW}Step 2: Generate new values${NC}"
echo "${RED}CUSTOMIZE THIS SECTION${NC}"
echo ""
echo "Example for SMTP:"
echo "  NEW_PASSWORD=\$(openssl rand -base64 24)"
echo "  # Then update password in email provider"
echo ""
echo "Example for API keys:"
echo "  # Create new key in provider dashboard"
echo "  # Copy new key here"
echo ""

read -p "Continue with rotation? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "Aborted"
    exit 1
fi

echo ""
echo "${YELLOW}Step 3: Update secret${NC}"
echo "Paste new secret JSON (or press Ctrl+C to abort):"
read -r NEW_SECRET

if [[ "$DRY_RUN" == "false" ]]; then
    if [[ "$BACKEND" == "aws" ]]; then
        aws secretsmanager update-secret \
            --secret-id "$SECRET_ID" \
            --secret-string "$NEW_SECRET"
    else
        infisical secrets set "DATA=${NEW_SECRET}" \
            --env "$ENV" \
            --path "/${BUCKET}" \
            --domain "${SECRETS_API_URL}"
    fi

    echo "${GREEN}✓${NC} Secret updated"
else
    echo "${CYAN}[DRY RUN]${NC} Would update secret"
fi

echo ""
echo "${YELLOW}Step 4: Wait for app refresh${NC}"
echo "Waiting 5 minutes for apps to pick up new secret..."

if [[ "$DRY_RUN" == "false" ]]; then
    sleep 300
    echo "${GREEN}✓${NC} Apps should have refreshed"
else
    echo "${CYAN}[DRY RUN]${NC} Would wait for refresh"
fi

echo ""
echo "${YELLOW}Step 5: Verify${NC}"
echo "${RED}CUSTOMIZE THIS SECTION${NC}"
echo "Test that new credentials work:"
echo "  - Check /status/secrets endpoint"
echo "  - Check application logs"
echo "  - Test the service manually"
echo ""

read -p "Verification successful? (y/N): " VERIFIED
if [[ "$VERIFIED" != "y" ]]; then
    echo "${RED}Verification failed - consider rollback${NC}"
    exit 1
fi

echo ""
echo "${YELLOW}Step 6: Clean up old values${NC}"
echo "${RED}CUSTOMIZE THIS SECTION${NC}"
echo ""
echo "Example for API keys:"
echo "  # Revoke old API key in provider dashboard"
echo ""
echo "Example for OAuth:"
echo "  # Delete old client secret in OAuth provider"
echo ""

read -p "Old values cleaned up? (y/N): " CLEANED
if [[ "$CLEANED" != "y" ]]; then
    echo "${YELLOW}⚠${NC} Remember to clean up old values manually"
fi

echo ""
echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo "${GREEN}  Rotation Complete!${NC}"
echo "${GREEN}═══════════════════════════════════════════════════════${NC}"

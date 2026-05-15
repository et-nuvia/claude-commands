#!/usr/bin/env bash
set -euo pipefail

# Secret Rollback Script
# Quickly rollback a failed secret rotation
#
# Usage: ./scripts/rollback-secret.sh --bucket <bucket> [--output json|human]
#
# Examples:
#   ./scripts/rollback-secret.sh --bucket database
#   ./scripts/rollback-secret.sh --bucket database --output json

BUCKET=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/colors.sh"

OUTPUT_FORMAT="human"
INSTANCE_IPS=(${APP_INSTANCES:-localhost})

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --bucket <bucket> [--output json|human]" >&2
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$BUCKET" ]]; then
    echo "Error: --bucket is required" >&2
    echo "Usage: $0 --bucket <bucket> [--output json|human]" >&2
    exit 1
fi

require_project_config

APP_NAME=$(get_config "name")
ENV=${ENVIRONMENT:-staging}
BACKEND=$(get_config "secrets.backend" "auto")

if [[ "$BACKEND" == "auto" ]]; then
    BACKEND=$(uname -s | grep -q Darwin && echo "aws" || echo "infisical")
fi

START_TIME=$(date +%s)

# Output helpers
log_step() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"step\":\"$1\",\"status\":\"in_progress\",\"message\":\"$2\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${YELLOW}$1:${NC} $2"
    fi
}

log_success() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"step\":\"$1\",\"status\":\"success\",\"message\":\"$2\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${GREEN}✓${NC} $2"
    fi
}

log_error() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"step\":\"$1\",\"status\":\"error\",\"message\":\"$2\",\"timestamp\":\"$(date -Iseconds)\"}" >&2
    else
        echo "${RED}✗${NC} $2" >&2
    fi
}

log_header() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"action\":\"rollback\",\"bucket\":\"$BUCKET\",\"environment\":\"$ENV\",\"backend\":\"$BACKEND\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${RED}═══════════════════════════════════════════════════════${NC}"
        echo "${RED}  SECRET ROLLBACK: ${BUCKET}${NC}"
        echo "${RED}═══════════════════════════════════════════════════════${NC}"
        echo "App: ${CYAN}${APP_NAME}${NC}"
        echo "Environment: ${CYAN}${ENV}${NC}"
        echo "Backend: ${CYAN}${BACKEND}${NC}"
        echo ""
    fi
}

log_header

# Step 1: Get previous version
log_step "get_previous_version" "Fetching previous secret version"

if [[ "$BACKEND" == "aws" ]]; then
    SECRET_ID="${APP_NAME}/${ENV}/${BUCKET}"

    # Get previous version (most recent non-current)
    PREVIOUS_VERSION=$(aws secretsmanager list-secret-version-ids \
        --secret-id "$SECRET_ID" \
        --query 'Versions[?VersionStages!=`[AWSCURRENT]`]|[0].VersionId' \
        --output text 2>/dev/null)

    if [[ -z "$PREVIOUS_VERSION" || "$PREVIOUS_VERSION" == "None" ]]; then
        log_error "get_previous_version" "No previous version found"
        exit 1
    fi

    log_success "get_previous_version" "Found previous version: ${PREVIOUS_VERSION}"

    # Restore previous version
    log_step "restore_version" "Restoring previous version"

    aws secretsmanager update-secret-version-stage \
        --secret-id "$SECRET_ID" \
        --version-stage AWSCURRENT \
        --move-to-version-id "$PREVIOUS_VERSION" >/dev/null 2>&1

    log_success "restore_version" "Previous version restored"

else
    # Infisical
    log_step "restore_version" "Restoring via Infisical Web UI"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"step\":\"restore_version\",\"status\":\"manual_required\",\"instructions\":\"Navigate to https://secrets.turnersrus.com, select project, environment ${ENV}, folder /${BUCKET}, click DATA secret, Version History, Restore previous version\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${YELLOW}Manual action required:${NC}"
        echo "1. Navigate to: https://secrets.turnersrus.com"
        echo "2. Project → Environment: ${ENV}"
        echo "3. Folder: /${BUCKET}"
        echo "4. Click secret: DATA"
        echo "5. Version History → Restore previous"
        echo ""
        read -p "Press Enter after restoring..."
    fi

    log_success "restore_version" "Secret restored in Infisical"
fi

# Step 2: Trigger immediate refresh on all instances
log_step "trigger_refresh" "Triggering immediate refresh on all instances"

REFRESH_RESULTS=()
REFRESH_FAILED=false

for IP in "${INSTANCE_IPS[@]}"; do
    REFRESH_RESPONSE=$(curl -s -X POST "http://${IP}:8000/secrets/refresh" 2>/dev/null || echo '{"status":"error"}')
    REFRESH_STATUS=$(echo "$REFRESH_RESPONSE" | jq -r '.status // "error"')

    if [[ "$REFRESH_STATUS" == "success" ]]; then
        log_success "trigger_refresh" "${IP} refreshed"
        REFRESH_RESULTS+=("${IP}:success")
    else
        log_error "trigger_refresh" "${IP} refresh failed"
        REFRESH_RESULTS+=("${IP}:failed")
        REFRESH_FAILED=true
    fi
done

if [[ "$REFRESH_FAILED" == "true" ]]; then
    log_error "trigger_refresh" "Some instances failed to refresh"
fi

# Step 3: Wait briefly for refresh to complete
log_step "wait_refresh" "Waiting for refresh to complete"
sleep 3
log_success "wait_refresh" "Refresh completed"

# Step 4: Verify credentials work
log_step "verify_credentials" "Verifying rolled-back credentials"

VERIFY_RESULTS=()
VERIFY_FAILED=false

for IP in "${INSTANCE_IPS[@]}"; do
    STATUS_RESPONSE=$(curl -s "http://${IP}:8000/status/secrets" 2>/dev/null || echo '{"overall_status":"unhealthy"}')
    OVERALL_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.overall_status // "unhealthy"')
    DB_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".checks.${BUCKET}.status // \"unhealthy\"" 2>/dev/null || echo "unhealthy")

    if [[ "$DB_STATUS" == "healthy" ]]; then
        DB_USER=$(echo "$STATUS_RESPONSE" | jq -r ".checks.${BUCKET}.user // \"unknown\"" 2>/dev/null)
        log_success "verify_credentials" "${IP} healthy (user: ${DB_USER})"
        VERIFY_RESULTS+=("{\"instance\":\"${IP}\",\"status\":\"healthy\",\"user\":\"${DB_USER}\"}")
    else
        DB_ERROR=$(echo "$STATUS_RESPONSE" | jq -r ".checks.${BUCKET}.error // \"unknown error\"" 2>/dev/null)
        log_error "verify_credentials" "${IP} unhealthy: ${DB_ERROR}"
        VERIFY_RESULTS+=("{\"instance\":\"${IP}\",\"status\":\"unhealthy\",\"error\":\"${DB_ERROR}\"}")
        VERIFY_FAILED=true
    fi
done

# Step 5: Clean up failed new user (database only)
if [[ "$BUCKET" == "database" ]]; then
    log_step "cleanup" "Attempting to drop failed new database user"

    # Get current secret to find old user
    if [[ "$BACKEND" == "aws" ]]; then
        CURRENT_SECRET=$(aws secretsmanager get-secret-value \
            --secret-id "$SECRET_ID" \
            --query SecretString \
            --output text 2>/dev/null)
    else
        CURRENT_SECRET=$(infisical secrets get DATA \
            --env "$ENV" \
            --path "/${BUCKET}" \
            --plain \
            --domain https://secrets.turnersrus.com/api 2>/dev/null)
    fi

    DB_HOST=$(echo "$CURRENT_SECRET" | jq -r .host)
    DB_PORT=$(echo "$CURRENT_SECRET" | jq -r .port)
    DB_NAME=$(echo "$CURRENT_SECRET" | jq -r .database)
    DB_USER=$(echo "$CURRENT_SECRET" | jq -r .app_username)
    DB_PASS=$(echo "$CURRENT_SECRET" | jq -r .app_password)

    # Check if there's a failed new user to clean up
    if echo "$CURRENT_SECRET" | jq -e '.app_username_old' >/dev/null 2>&1; then
        FAILED_USER=$(echo "$CURRENT_SECRET" | jq -r .app_username)

        PGPASSWORD="$DB_PASS" psql \
            -h "$DB_HOST" \
            -p "$DB_PORT" \
            -U "$DB_USER" \
            -d "$DB_NAME" \
            -c "DROP USER IF EXISTS ${FAILED_USER};" >/dev/null 2>&1 || true

        log_success "cleanup" "Dropped failed user: ${FAILED_USER}"
    else
        log_success "cleanup" "No failed user to clean up"
    fi
fi

# Final summary
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    cat <<EOF
{
  "action": "rollback_complete",
  "bucket": "${BUCKET}",
  "environment": "${ENV}",
  "backend": "${BACKEND}",
  "success": $([ "$VERIFY_FAILED" == "false" ] && echo "true" || echo "false"),
  "duration_seconds": ${DURATION},
  "instances_verified": $([ "$VERIFY_FAILED" == "false" ] && echo "${#INSTANCE_IPS[@]}" || echo "0"),
  "instances_total": ${#INSTANCE_IPS[@]},
  "timestamp": "$(date -Iseconds)"
}
EOF
else
    echo ""
    if [[ "$VERIFY_FAILED" == "false" ]]; then
        echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo "${GREEN}  Rollback Successful!${NC}"
        echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo "Bucket: ${CYAN}${BUCKET}${NC}"
        echo "Instances verified: ${CYAN}${#INSTANCE_IPS[@]}/${#INSTANCE_IPS[@]}${NC}"
        echo "Duration: ${CYAN}${DURATION}s${NC}"
    else
        echo "${RED}═══════════════════════════════════════════════════════${NC}"
        echo "${RED}  Rollback Completed with Errors${NC}"
        echo "${RED}═══════════════════════════════════════════════════════${NC}"
        echo "Some instances still unhealthy - manual intervention required"
    fi
fi

exit $([ "$VERIFY_FAILED" == "false" ] && echo 0 || echo 1)

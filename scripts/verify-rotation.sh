#!/usr/bin/env bash
set -euo pipefail

# Secret Rotation Verification Script
# Comprehensive monitoring after secret rotation
#
# Usage: ./scripts/verify-rotation.sh [--output json|human] [--duration 15]
#
# What it does:
# 1. Triggers immediate refresh on all instances
# 2. Checks /status/secrets for credential validation
# 3. Monitors Docker logs for errors
# 4. Runs smoke tests after 1 minute
# 5. Monitors /health/secrets every minute for specified duration
#
# Examples:
#   ./scripts/verify-rotation.sh
#   ./scripts/verify-rotation.sh --duration 15
#   ./scripts/verify-rotation.sh --output json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/colors.sh"

OUTPUT_FORMAT="human"
MONITOR_DURATION_MINUTES=15
INSTANCE_IPS=(${APP_INSTANCES:-localhost})
DOCKER_SERVICES=(${DOCKER_SERVICES:-backend})

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --duration)
            MONITOR_DURATION_MINUTES="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

ENV=${ENVIRONMENT:-staging}
APP_NAME=$(get_app_name)
START_TIME=$(date +%s)

# Check if smoke test script exists
SMOKE_TEST_SCRIPT=""
if [[ -f "${SCRIPT_DIR}/smoke-tests.sh" ]]; then
    SMOKE_TEST_SCRIPT="${SCRIPT_DIR}/smoke-tests.sh"
elif [[ -f "./scripts/smoke-tests.sh" ]]; then
    SMOKE_TEST_SCRIPT="./scripts/smoke-tests.sh"
fi

# Output helpers
log_step() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"step\":\"$1\",\"status\":\"in_progress\",\"message\":\"$2\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${BLUE}▸${NC} $2"
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

log_warning() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"step\":\"$1\",\"status\":\"warning\",\"message\":\"$2\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${YELLOW}⚠${NC} $2"
    fi
}

log_header() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "{\"action\":\"verify_rotation\",\"app\":\"$APP_NAME\",\"environment\":\"$ENV\",\"monitor_duration_minutes\":${MONITOR_DURATION_MINUTES},\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo "${BLUE}  ROTATION VERIFICATION${NC}"
        echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo "App: ${CYAN}${APP_NAME}${NC}"
        echo "Environment: ${CYAN}${ENV}${NC}"
        echo "Instances: ${CYAN}${#INSTANCE_IPS[@]}${NC}"
        echo "Monitor duration: ${CYAN}${MONITOR_DURATION_MINUTES} minutes${NC}"
        echo ""
    fi
}

log_header

# Step 1: Trigger immediate refresh on all instances
log_step "trigger_refresh" "Triggering immediate refresh on all instances"

REFRESH_RESULTS=()
REFRESH_FAILED=false

for IP in "${INSTANCE_IPS[@]}"; do
    REFRESH_RESPONSE=$(curl -s -X POST "http://${IP}:8000/secrets/refresh" -w "\n%{http_code}" 2>/dev/null || echo -e '\n000')
    HTTP_CODE="${REFRESH_RESPONSE##*$'\n'}"
    BODY="${REFRESH_RESPONSE%$'\n'*}"

    if [[ "$HTTP_CODE" == "200" ]]; then
        REFRESH_STATUS=$(echo "$BODY" | jq -r '.status // "error"')
        if [[ "$REFRESH_STATUS" == "success" ]]; then
            log_success "trigger_refresh" "${IP}: Refresh triggered"
            REFRESH_RESULTS+=("${IP}:success")
        else
            log_error "trigger_refresh" "${IP}: Refresh returned non-success status"
            REFRESH_RESULTS+=("${IP}:failed")
            REFRESH_FAILED=true
        fi
    else
        log_error "trigger_refresh" "${IP}: HTTP ${HTTP_CODE}"
        REFRESH_RESULTS+=("${IP}:failed")
        REFRESH_FAILED=true
    fi
done

if [[ "$REFRESH_FAILED" == "true" ]]; then
    log_error "trigger_refresh" "Some instances failed to refresh"
    exit 1
fi

# Step 2: Wait for refresh to complete
log_step "wait_refresh" "Waiting 5 seconds for refresh to complete"
sleep 5
log_success "wait_refresh" "Refresh window complete"

# Step 3: Check /status/secrets for credential validation
log_step "validate_credentials" "Validating credentials on all instances"

STATUS_RESULTS=()
VALIDATION_FAILED=false

for IP in "${INSTANCE_IPS[@]}"; do
    STATUS_RESPONSE=$(curl -s "http://${IP}:8000/status/secrets" 2>/dev/null || echo '{"overall_status":"unhealthy"}')
    OVERALL_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.overall_status // "unhealthy"')

    if [[ "$OVERALL_STATUS" == "healthy" ]]; then
        # Get details of all checks
        CHECKS=$(echo "$STATUS_RESPONSE" | jq -r '.checks | keys[]' 2>/dev/null)
        CHECK_SUMMARY=""
        for CHECK in $CHECKS; do
            CHECK_STATUS=$(echo "$STATUS_RESPONSE" | jq -r ".checks.${CHECK}.status")
            if [[ "$CHECK_STATUS" == "healthy" ]]; then
                CHECK_SUMMARY="${CHECK_SUMMARY} ${CHECK}:✓"
            else
                CHECK_SUMMARY="${CHECK_SUMMARY} ${CHECK}:✗"
            fi
        done

        log_success "validate_credentials" "${IP}: Healthy${CHECK_SUMMARY}"
        STATUS_RESULTS+=("{\"instance\":\"${IP}\",\"status\":\"healthy\"}")
    else
        log_error "validate_credentials" "${IP}: ${OVERALL_STATUS}"

        # Get specific failures
        FAILED_CHECKS=$(echo "$STATUS_RESPONSE" | jq -r '.checks | to_entries[] | select(.value.status != "healthy") | "\(.key): \(.value.error // .value.status)"' 2>/dev/null)
        if [[ -n "$FAILED_CHECKS" ]]; then
            while IFS= read -r line; do
                log_error "validate_credentials" "  ${IP}: ${line}"
            done <<< "$FAILED_CHECKS"
        fi

        STATUS_RESULTS+=("{\"instance\":\"${IP}\",\"status\":\"${OVERALL_STATUS}\"}")
        VALIDATION_FAILED=true
    fi
done

if [[ "$VALIDATION_FAILED" == "true" ]]; then
    log_error "validate_credentials" "Credential validation failed on some instances"
    exit 1
fi

# Step 4: Check Docker logs for errors
log_step "check_docker_logs" "Checking Docker logs for recent errors"

DOCKER_ERRORS_FOUND=false

for SERVICE in "${DOCKER_SERVICES[@]}"; do
    # Get logs from last 2 minutes
    LOGS=$(docker compose logs --tail=100 --since=2m "$SERVICE" 2>/dev/null || docker logs --tail=100 --since=2m "$SERVICE" 2>/dev/null || echo "")

    if [[ -n "$LOGS" ]]; then
        # Check for common error patterns
        ERROR_COUNT=$(echo "$LOGS" | grep -iE "(error|exception|failed|fatal)" | grep -v "error_code=0" | wc -l)

        if [[ $ERROR_COUNT -gt 0 ]]; then
            log_warning "check_docker_logs" "${SERVICE}: Found ${ERROR_COUNT} potential errors in logs"

            # Show first few errors
            echo "$LOGS" | grep -iE "(error|exception|failed|fatal)" | grep -v "error_code=0" | head -5 | while IFS= read -r line; do
                log_warning "check_docker_logs" "  ${SERVICE}: ${line}"
            done

            DOCKER_ERRORS_FOUND=true
        else
            log_success "check_docker_logs" "${SERVICE}: No errors found in recent logs"
        fi
    else
        log_warning "check_docker_logs" "${SERVICE}: Could not retrieve logs"
    fi
done

if [[ "$DOCKER_ERRORS_FOUND" == "true" ]]; then
    log_warning "check_docker_logs" "Errors found in Docker logs - review recommended"
fi

# Step 5: Run smoke tests after 1 minute
log_step "smoke_tests" "Waiting 1 minute before running smoke tests"
sleep 60

if [[ -n "$SMOKE_TEST_SCRIPT" && -x "$SMOKE_TEST_SCRIPT" ]]; then
    log_step "smoke_tests" "Running smoke tests: ${SMOKE_TEST_SCRIPT}"

    SMOKE_OUTPUT=$("$SMOKE_TEST_SCRIPT" 2>&1)
    SMOKE_EXIT_CODE=$?

    if [[ $SMOKE_EXIT_CODE -eq 0 ]]; then
        log_success "smoke_tests" "Smoke tests passed"
    else
        log_error "smoke_tests" "Smoke tests failed (exit code: ${SMOKE_EXIT_CODE})"
        echo "$SMOKE_OUTPUT" | tail -20
        exit 1
    fi
else
    log_warning "smoke_tests" "Smoke test script not found or not executable"
fi

# Step 6: Monitor /health/secrets every minute for specified duration
log_step "continuous_monitoring" "Starting continuous monitoring (${MONITOR_DURATION_MINUTES} minutes)"

MONITORING_START=$(date +%s)
MONITORING_END=$((MONITORING_START + MONITOR_DURATION_MINUTES * 60))
CHECK_COUNT=0
CHECK_FAILURES=0

while [[ $(date +%s) -lt $MONITORING_END ]]; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    CURRENT_MINUTE=$((CHECK_COUNT))

    log_step "health_check_${CHECK_COUNT}" "Health check ${CURRENT_MINUTE}/${MONITOR_DURATION_MINUTES}"

    for IP in "${INSTANCE_IPS[@]}"; do
        HEALTH_RESPONSE=$(curl -s "http://${IP}:8000/health/secrets" 2>/dev/null || echo '{}')

        SECRETS_LOADED=$(echo "$HEALTH_RESPONSE" | jq -r '.secrets_loaded_at // "unknown"')
        BUCKETS_LOADED=$(echo "$HEALTH_RESPONSE" | jq -r '.buckets_loaded | length // 0')
        NEXT_REFRESH=$(echo "$HEALTH_RESPONSE" | jq -r '.next_refresh_at // "unknown"')

        if [[ "$SECRETS_LOADED" != "unknown" && $BUCKETS_LOADED -gt 0 ]]; then
            # Calculate time since last load
            LOADED_EPOCH=$(date -d "$SECRETS_LOADED" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            SECONDS_SINCE=$((NOW_EPOCH - LOADED_EPOCH))
            MINUTES_SINCE=$((SECONDS_SINCE / 60))

            log_success "health_check_${CHECK_COUNT}" "${IP}: Healthy (${BUCKETS_LOADED} buckets, loaded ${MINUTES_SINCE}m ago)"
        else
            log_error "health_check_${CHECK_COUNT}" "${IP}: Unhealthy or invalid response"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    done

    # Quick status check
    STATUS_CHECK=$(curl -s "http://${INSTANCE_IPS[0]}:8000/status/secrets" 2>/dev/null || echo '{"overall_status":"unhealthy"}')
    STATUS_OVERALL=$(echo "$STATUS_CHECK" | jq -r '.overall_status // "unhealthy"')

    if [[ "$STATUS_OVERALL" != "healthy" ]]; then
        log_error "health_check_${CHECK_COUNT}" "Status check failed - credentials no longer valid"
        exit 1
    fi

    # Check Docker logs for new errors
    for SERVICE in "${DOCKER_SERVICES[@]}"; do
        NEW_ERRORS=$(docker compose logs --tail=20 --since=1m "$SERVICE" 2>/dev/null | grep -iE "(error|exception|failed|fatal)" | grep -v "error_code=0" | wc -l)
        if [[ $NEW_ERRORS -gt 0 ]]; then
            log_warning "health_check_${CHECK_COUNT}" "${SERVICE}: ${NEW_ERRORS} new errors in logs"
        fi
    done

    # Wait 60 seconds before next check (unless it's the last check)
    if [[ $(date +%s) -lt $((MONITORING_END - 60)) ]]; then
        sleep 60
    fi
done

# Final summary
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", (${CHECK_COUNT} - ${CHECK_FAILURES}) * 100.0 / ${CHECK_COUNT}}")

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    cat <<EOF
{
  "action": "verify_rotation_complete",
  "app": "${APP_NAME}",
  "environment": "${ENV}",
  "success": $([ "$CHECK_FAILURES" -eq 0 ] && echo "true" || echo "false"),
  "duration_seconds": ${TOTAL_DURATION},
  "health_checks_performed": ${CHECK_COUNT},
  "health_checks_failed": ${CHECK_FAILURES},
  "success_rate_percent": ${SUCCESS_RATE},
  "instances_monitored": ${#INSTANCE_IPS[@]},
  "timestamp": "$(date -Iseconds)"
}
EOF
else
    echo ""
    if [[ $CHECK_FAILURES -eq 0 ]]; then
        echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo "${GREEN}  Verification Complete - All Checks Passed!${NC}"
        echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
    else
        echo "${YELLOW}═══════════════════════════════════════════════════════${NC}"
        echo "${YELLOW}  Verification Complete - Some Checks Failed${NC}"
        echo "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    fi
    echo "Total duration: ${CYAN}${TOTAL_DURATION}s ($(($TOTAL_DURATION / 60))m)${NC}"
    echo "Health checks: ${CYAN}${CHECK_COUNT} performed, ${CHECK_FAILURES} failed${NC}"
    echo "Success rate: ${CYAN}${SUCCESS_RATE}%${NC}"
    echo "Instances: ${CYAN}${#INSTANCE_IPS[@]} monitored${NC}"
fi

exit $([ "$CHECK_FAILURES" -eq 0 ] && echo 0 || echo 1)

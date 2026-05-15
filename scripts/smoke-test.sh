#!/usr/bin/env bash
set -euo pipefail

# Smoke Test Script
# Verify deployment is healthy
# Usage: ./scripts/smoke-test.sh --url <environment_url>
# Copy to project: cp ~/.claude/scripts/smoke-test.sh ./scripts/

BASE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) BASE_URL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --url <environment_url>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "Error: --url is required" >&2
  echo "Usage: $0 --url <environment_url>" >&2
  exit 1
fi

# Remove trailing slash
BASE_URL="${BASE_URL%/}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

FAILURES=0

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
    ((FAILURES++))
}

check_endpoint() {
    local name="$1"
    local path="$2"
    local expected_status="${3:-200}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${path}" || echo "000")

    if [[ "${status}" == "${expected_status}" ]]; then
        log_success "${name}: ${path} (${status})"
    else
        log_error "${name}: ${path} expected ${expected_status}, got ${status}"
    fi
}

check_json_field() {
    local name="$1"
    local path="$2"
    local field="$3"
    local expected="$4"

    local actual
    actual=$(curl -s "${BASE_URL}${path}" | jq -r "${field}" 2>/dev/null || echo "null")

    if [[ "${actual}" == "${expected}" ]]; then
        log_success "${name}: ${field} = ${expected}"
    else
        log_error "${name}: ${field} expected '${expected}', got '${actual}'"
    fi
}

echo "Running smoke tests against ${BASE_URL}"
echo "────────────────────────────────────────"

# ─────────────────────────────────────────
# Health Checks
# ─────────────────────────────────────────
check_endpoint "Health" "/health"
check_endpoint "Readiness" "/ready"

# ─────────────────────────────────────────
# API Endpoints
# ─────────────────────────────────────────
check_endpoint "API Root" "/api/v1"
check_json_field "API Version" "/api/v1" ".version" "1.0.0"

# ─────────────────────────────────────────
# Frontend (if applicable)
# ─────────────────────────────────────────
check_endpoint "Frontend" "/"

# ─────────────────────────────────────────
# Summary
# ─────────────────────────────────────────
echo "────────────────────────────────────────"

if [[ ${FAILURES} -eq 0 ]]; then
    echo -e "${GREEN}All smoke tests passed!${NC}"
    exit 0
else
    echo -e "${RED}${FAILURES} smoke test(s) failed${NC}"
    exit 1
fi

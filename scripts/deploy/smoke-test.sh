#!/usr/bin/env bash
# =============================================================================
# Smoke Test Script (Config-Driven)
# =============================================================================
# Runs health checks on a deployed environment.
# Reads test configuration from PROJECT.yaml (smoke_tests section).
# Supports SSH (manual) and SSM (CI/CD) transports.
#
# Static tests (always run):
#   - Health endpoint (generic pattern matching)
#   - Container status (docker compose running count)
#   - Container restarts (restart loop detection)
#
# Dynamic tests (from PROJECT.yaml smoke_tests section):
#   - Public endpoints: verify accessible with X-Forwarded-For header
#   - Private endpoints: verify 403 with public IP, 200/503 without
#
# Domain check (from deployment.<env>.public_url):
#   - Runs from CI runner after SSH/SSM block
#   - Tests full DNS -> CDN -> Load Balancer -> Server chain
#
# Usage:
#   ./smoke-test.sh --env staging
#   ./smoke-test.sh --env staging --ssm
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Defaults
ENVIRONMENT=""
USE_SSM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --ssm) USE_SSM=true; shift ;;
    -h|--help)
      echo "Usage: $0 --env <staging|production> [--ssm]"
      echo ""
      echo "Runs smoke tests on deployed environment."
      echo "Reads test config from PROJECT.yaml (smoke_tests section)."
      echo ""
      echo "Options:"
      echo "  --env ENV      Target environment (staging|production)"
      echo "  --ssm          Use AWS SSM instead of SSH (for CI/CD)"
      echo "  -h, --help     Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required args
[[ -z "$ENVIRONMENT" ]] && { echo "Error: --env required (staging|production)"; exit 1; }

# Load environment config
load_config "$ENVIRONMENT"

# Read smoke test config from PROJECT.yaml
if [[ -n "${PROJECT_ROOT:-}" ]] && [[ -f "$PROJECT_ROOT/PROJECT.yaml" ]]; then
  INTERNAL_URL=$(_yaml_get ".deployment.${ENVIRONMENT}.url")
  APP_PORT="${INTERNAL_URL##*:}"
  [[ "$APP_PORT" =~ ^[0-9]+$ ]] || APP_PORT=""
  PUBLIC_URL=$(_yaml_get ".deployment.${ENVIRONMENT}.public_url")
  PUBLIC_EP_COUNT=$(yq eval '.smoke_tests.public_endpoints // [] | length' "$PROJECT_ROOT/PROJECT.yaml" 2>/dev/null || echo "0")
  PRIVATE_EP_COUNT=$(yq eval '.smoke_tests.private_endpoints // [] | length' "$PROJECT_ROOT/PROJECT.yaml" 2>/dev/null || echo "0")
else
  APP_PORT=""
  PUBLIC_URL=""
  PUBLIC_EP_COUNT=0
  PRIVATE_EP_COUNT=0
fi

# Fallbacks
APP_PORT="${APP_PORT:-3000}"

TOTAL_TESTS=$((3 + PUBLIC_EP_COUNT + PRIVATE_EP_COUNT))

# Load transport helper
if [[ "$USE_SSM" == "true" ]]; then
  source "$SCRIPT_DIR/lib/ssm.sh"
  INSTANCE_ID=$(get_instance_id "$ENVIRONMENT")
  if [[ -z "$INSTANCE_ID" ]]; then
    echo "Error: No instance ID found for ${ENVIRONMENT}"
    exit 1
  fi
else
  source "$SCRIPT_DIR/lib/ssh.sh"
  ssh_get_config "$ENVIRONMENT" || exit 1
fi

log_header "Running Smoke Tests"
echo "  Environment: $ENVIRONMENT"
if [[ "$USE_SSM" == "true" ]]; then
  echo "  Instance:    $INSTANCE_ID"
else
  echo "  Host:        $SSH_HOST"
fi
echo "  Tests:       $TOTAL_TESTS"
echo "═══════════════════════════════════════════════════════════════"

# Test SSH connection (SSH mode only)
if [[ "$USE_SSM" != "true" ]]; then
  echo ""
  ssh_test_connection "$ENVIRONMENT" || exit 1
fi

# =============================================================================
# Build remote smoke test command
# =============================================================================

# --- Static tests (always present) ---
SMOKE_TEST_COMMAND=$(cat <<TESTEOF
set -euo pipefail

echo ""
echo "Performing health checks..."
sleep 3

FAILED=0

# [1/${TOTAL_TESTS}] Health endpoint
echo ""
echo "[1/${TOTAL_TESTS}] Checking health endpoint..."
for i in 1 2 3 4 5; do
  HEALTH=\$(curl -sf --max-time 10 http://localhost:${APP_PORT}${HEALTH_CHECK_PATH} 2>/dev/null || echo "")
  if [[ -n "\$HEALTH" ]]; then
    echo "  Health response: \$HEALTH"
    if echo "\$HEALTH" | grep -qiE '"(healthy|ok|up)"'; then
      echo "  ✓ Service is healthy"
    else
      echo "  ✗ Service not healthy"
      FAILED=1
    fi
    break
  fi
  echo "  Retrying (\$i/5)..."
  sleep 3
done

if [[ -z "\${HEALTH:-}" ]]; then
  echo "  ✗ Health endpoint not responding"
  FAILED=1
fi

# [2/${TOTAL_TESTS}] Container health status (all compose services)
echo ""
echo "[2/${TOTAL_TESTS}] Checking container health status..."
cd ${DEPLOY_PATH}
UNHEALTHY_SVCS=0
for SVC in \$(docker compose ps --format "{{.Name}}" 2>/dev/null); do
  SVC_STATUS=\$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "\$SVC" 2>/dev/null || echo "missing")
  if [[ "\$SVC_STATUS" == "healthy" ]] || [[ "\$SVC_STATUS" == "no-healthcheck" ]]; then
    echo "  ✓ \$SVC: \$SVC_STATUS"
  else
    echo "  ✗ \$SVC: \$SVC_STATUS"
    UNHEALTHY_SVCS=\$((UNHEALTHY_SVCS + 1))
  fi
done
if [[ \$UNHEALTHY_SVCS -gt 0 ]]; then
  FAILED=1
  docker compose ps
fi

# [3/${TOTAL_TESTS}] Container restarts
echo ""
echo "[3/${TOTAL_TESTS}] Checking for container restarts..."
RESTARTS=\$(docker compose ps --format "{{.Name}}: {{.Status}}" 2>/dev/null | grep -c "Restarting" || true)
if [[ "\$RESTARTS" -eq 0 ]]; then
  echo "  ✓ No containers restarting"
else
  echo "  ✗ \$RESTARTS container(s) restarting"
  FAILED=1
fi
TESTEOF
)

TEST_NUM=3

# --- Dynamic public endpoint tests (from smoke_tests.public_endpoints) ---
for i in $(seq 0 $((PUBLIC_EP_COUNT - 1))); do
  EP_PATH=$(yq eval ".smoke_tests.public_endpoints[$i].path" "$PROJECT_ROOT/PROJECT.yaml")
  EP_EXPECT=$(yq eval ".smoke_tests.public_endpoints[$i].expect // \"status:200\"" "$PROJECT_ROOT/PROJECT.yaml")
  TEST_NUM=$((TEST_NUM + 1))

  if [[ "$EP_EXPECT" == "html" ]]; then
    SMOKE_TEST_COMMAND+=$(cat <<TESTEOF

# [${TEST_NUM}/${TOTAL_TESTS}] Public endpoint: ${EP_PATH}
echo ""
echo "[${TEST_NUM}/${TOTAL_TESTS}] Checking public IP accessibility (${EP_PATH})..."
PUBLIC_RESPONSE=\$(curl -s --max-time 10 -H 'X-Forwarded-For: 8.8.8.8' http://localhost:${APP_PORT}${EP_PATH} 2>/dev/null || echo "")
if echo "\$PUBLIC_RESPONSE" | grep -q '<!DOCTYPE html>'; then
  echo "  ✓ ${EP_PATH} accessible from public IPs"
elif echo "\$PUBLIC_RESPONSE" | grep -q '"Forbidden"'; then
  echo "  ✗ Public IPs blocked! Middleware is rejecting public traffic"
  FAILED=1
else
  echo "  ✗ Unexpected response from public IP test"
  echo "  Response (first 200 chars): \$(echo "\$PUBLIC_RESPONSE" | head -c 200)"
  FAILED=1
fi
TESTEOF
    )
  else
    EXPECTED_STATUS="${EP_EXPECT#status:}"
    SMOKE_TEST_COMMAND+=$(cat <<TESTEOF

# [${TEST_NUM}/${TOTAL_TESTS}] Public endpoint: ${EP_PATH}
echo ""
echo "[${TEST_NUM}/${TOTAL_TESTS}] Checking public IP accessibility (${EP_PATH})..."
PUBLIC_STATUS=\$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 8.8.8.8' http://localhost:${APP_PORT}${EP_PATH} 2>/dev/null || echo "000")
if [[ "\$PUBLIC_STATUS" == "${EXPECTED_STATUS}" ]]; then
  echo "  ✓ ${EP_PATH} returned expected HTTP ${EXPECTED_STATUS} from public IPs"
else
  echo "  ✗ ${EP_PATH} returned HTTP \$PUBLIC_STATUS (expected ${EXPECTED_STATUS})"
  FAILED=1
fi
TESTEOF
    )
  fi
done

# --- Dynamic private endpoint tests (from smoke_tests.private_endpoints) ---
for i in $(seq 0 $((PRIVATE_EP_COUNT - 1))); do
  EP_PATH=$(yq eval ".smoke_tests.private_endpoints[$i].path" "$PROJECT_ROOT/PROJECT.yaml")
  TEST_NUM=$((TEST_NUM + 1))

  SMOKE_TEST_COMMAND+=$(cat <<TESTEOF

# [${TEST_NUM}/${TOTAL_TESTS}] Private endpoint: ${EP_PATH}
echo ""
echo "[${TEST_NUM}/${TOTAL_TESTS}] Checking private endpoint access control (${EP_PATH})..."
PRIVATE_EP_PUBLIC=\$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 8.8.8.8' http://localhost:${APP_PORT}${EP_PATH} 2>/dev/null || echo "000")
if [[ "\$PRIVATE_EP_PUBLIC" == "403" ]]; then
  echo "  ✓ ${EP_PATH} correctly blocks public IPs (HTTP 403)"
else
  echo "  ✗ ${EP_PATH} NOT blocking public IPs (HTTP \$PRIVATE_EP_PUBLIC, expected 403)"
  FAILED=1
fi

PRIVATE_EP_LOCAL=\$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}${EP_PATH} 2>/dev/null || echo "000")
if [[ "\$PRIVATE_EP_LOCAL" == "200" ]] || [[ "\$PRIVATE_EP_LOCAL" == "503" ]]; then
  echo "  ✓ ${EP_PATH} accessible from private IPs (HTTP \$PRIVATE_EP_LOCAL)"
else
  echo "  ✗ ${EP_PATH} not accessible from private IPs (HTTP \$PRIVATE_EP_LOCAL, expected 200 or 503)"
  FAILED=1
fi
TESTEOF
  )
done

# --- Summary block ---
SMOKE_TEST_COMMAND+=$(cat <<'TESTEOF'

echo ""
echo "============================================"
if [[ "$FAILED" -eq 0 ]]; then
  echo "  All smoke tests passed!"
  echo "============================================"
  exit 0
else
  echo "  SMOKE TESTS FAILED"
  echo "============================================"
  echo ""
  echo "Container logs:"
  docker compose logs --tail=30
  exit 1
fi
TESTEOF
)

# =============================================================================
# Execute via the appropriate transport
# =============================================================================

echo ""
echo "Running health checks..."

if [[ "$USE_SSM" == "true" ]]; then
  if ! ssm_run_command "$INSTANCE_ID" "$SMOKE_TEST_COMMAND" 120; then
    echo ""
    log_header "SMOKE TESTS FAILED"
    exit 1
  fi
else
  if ! ssh_run_command "$ENVIRONMENT" "$SMOKE_TEST_COMMAND"; then
    echo ""
    log_header "SMOKE TESTS FAILED"
    exit 1
  fi
fi

# =============================================================================
# Domain accessibility check (runs from CI runner, not on server)
# =============================================================================

if [[ -n "${PUBLIC_URL:-}" ]]; then
  echo ""
  log_header "Checking Domain Accessibility"
  echo "  URL: $PUBLIC_URL"
  echo ""

  DOMAIN_OK=false
  for ATTEMPT in 1 2 3; do
    if [[ $ATTEMPT -gt 1 ]]; then
      WAIT=$((ATTEMPT * 5))
      echo "  Retrying in ${WAIT}s (attempt $ATTEMPT/3)..."
      sleep "$WAIT"
    fi
    DOMAIN_RESPONSE=$(curl -sf --max-time 15 "$PUBLIC_URL" 2>/dev/null || echo "")
    if [[ -n "$DOMAIN_RESPONSE" ]]; then
      echo "  ✓ $PUBLIC_URL is accessible"
      DOMAIN_OK=true
      break
    fi
  done

  if [[ "$DOMAIN_OK" != "true" ]]; then
    echo "  ⚠ $PUBLIC_URL is not responding from CI runner"
    echo "  NOTE: Server-side health checks passed. Domain check is non-blocking."
  fi
fi

log_header "Smoke Tests Passed"

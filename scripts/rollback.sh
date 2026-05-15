#!/usr/bin/env bash
set -euo pipefail

# Rollback Script
# Revert to previous deployment
# Usage: rollback.sh --environment <env> [--target-tag <tag>]
# Copy to project: cp ~/.claude/scripts/rollback.sh ./scripts/

ENVIRONMENT=""
TARGET_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --target-tag)  TARGET_TAG="$2";  shift 2 ;;
    -h|--help)
      echo "Usage: $0 --environment <env> [--target-tag <tag>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Error: --environment is required" >&2
  echo "Usage: $0 --environment <env> [--target-tag <tag>]" >&2
  exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[rollback]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[rollback]${NC} $1"
}

error() {
    echo -e "${RED}[rollback]${NC} $1" >&2
    exit 1
}

# Validate environment
case "${ENVIRONMENT}" in
    development|staging|production)
        log "Rolling back ${ENVIRONMENT}"
        ;;
    *)
        error "Invalid environment: ${ENVIRONMENT}"
        ;;
esac

# ─────────────────────────────────────────
# Get previous version if not specified
# ─────────────────────────────────────────
if [[ -z "${TARGET_TAG}" ]]; then
    log "Finding previous deployment..."

    # Example: Get previous tag from deployment history
    # For ECS:
    # TARGET_TAG=$(aws ecs describe-services \
    #     --cluster "${CLUSTER}" \
    #     --services "${SERVICE}" \
    #     --query 'services[0].deployments[1].taskDefinition' \
    #     --output text | grep -oP ':\K[^:]+$')

    # For Kubernetes:
    # TARGET_TAG=$(kubectl rollout history deployment/myapp \
    #     --namespace="${ENVIRONMENT}" \
    #     -o jsonpath='{.metadata.annotations.kubernetes\.io/change-cause}' \
    #     --revision=$(($(kubectl rollout history deployment/myapp --namespace="${ENVIRONMENT}" | tail -1 | awk '{print $1}') - 1)))

    # Fallback: check git for previous tag
    if [[ -z "${TARGET_TAG}" ]]; then
        TARGET_TAG=$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo "")
    fi

    if [[ -z "${TARGET_TAG}" ]]; then
        error "Could not determine previous version. Please specify target tag."
    fi
fi

log "Target version: ${TARGET_TAG}"

# ─────────────────────────────────────────
# Confirm rollback for production
# ─────────────────────────────────────────
if [[ "${ENVIRONMENT}" == "production" ]] && [[ "${CI:-false}" != "true" ]]; then
    warn "⚠️  PRODUCTION ROLLBACK to ${TARGET_TAG}"
    warn "Press Enter to continue or Ctrl+C to cancel..."
    read -r
fi

# ─────────────────────────────────────────
# Execute rollback
# ─────────────────────────────────────────

# Example: Kubernetes rollback
# kubectl rollout undo deployment/myapp --namespace="${ENVIRONMENT}"

# Example: ECS rollback (redeploy previous task definition)
# aws ecs update-service \
#     --cluster "${CLUSTER}" \
#     --service "${SERVICE}" \
#     --task-definition "myapp:${TARGET_TAG}" \
#     --force-new-deployment

# Example: Docker Compose rollback
# ssh "deploy@${ENVIRONMENT}.example.com" \
#     "cd /app && docker compose pull myapp:${TARGET_TAG} && docker compose up -d"

log "Rollback initiated to ${TARGET_TAG}"

# ─────────────────────────────────────────
# Wait and verify
# ─────────────────────────────────────────
log "Waiting for rollback to complete..."

# Example: Kubernetes wait
# kubectl rollout status deployment/myapp --namespace="${ENVIRONMENT}" --timeout=300s

# Example: ECS wait
# aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"

log "Rollback complete!"

# Run smoke tests to verify
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/smoke-test.sh" ]]; then
    log "Running smoke tests..."
    case "${ENVIRONMENT}" in
        development) URL="https://dev.example.com" ;;
        staging) URL="https://staging.example.com" ;;
        production) URL="https://example.com" ;;
    esac
    "${SCRIPT_DIR}/smoke-test.sh" "${URL}"
fi

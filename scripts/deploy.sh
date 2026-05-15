#!/usr/bin/env bash
set -euo pipefail

# Deployment Script
# Usage: ./scripts/deploy.sh --environment <env> --image-tag <tag>
# Copy to project: cp ~/.claude/scripts/deploy.sh ./scripts/

ENVIRONMENT=""
IMAGE_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --image-tag)   IMAGE_TAG="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 --environment <env> --image-tag <tag>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ENVIRONMENT" || -z "$IMAGE_TAG" ]]; then
  echo "Error: --environment and --image-tag are required" >&2
  echo "Usage: $0 --environment <env> --image-tag <tag>" >&2
  exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[deploy]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[deploy]${NC} $1"
}

error() {
    echo -e "${RED}[deploy]${NC} $1" >&2
    exit 1
}

# Validate environment
case "${ENVIRONMENT}" in
    development|staging|production)
        log "Deploying to ${ENVIRONMENT}"
        ;;
    *)
        error "Invalid environment: ${ENVIRONMENT}. Must be development, staging, or production"
        ;;
esac

# Production safety check
if [[ "${ENVIRONMENT}" == "production" ]]; then
    if [[ "${CI:-false}" != "true" ]]; then
        warn "Production deployment outside CI - are you sure? (Ctrl+C to cancel)"
        sleep 5
    fi
fi

# ─────────────────────────────────────────
# Configure based on environment
# ─────────────────────────────────────────
case "${ENVIRONMENT}" in
    development)
        CLUSTER="dev-cluster"
        SERVICE="myapp-dev"
        ;;
    staging)
        CLUSTER="staging-cluster"
        SERVICE="myapp-staging"
        ;;
    production)
        CLUSTER="prod-cluster"
        SERVICE="myapp-prod"
        ;;
esac

# ─────────────────────────────────────────
# Deploy (customize for your infrastructure)
# ─────────────────────────────────────────

# Example: ECS deployment
# aws ecs update-service \
#     --cluster "${CLUSTER}" \
#     --service "${SERVICE}" \
#     --force-new-deployment

# Example: Kubernetes deployment
# kubectl set image deployment/myapp \
#     myapp="${IMAGE_REGISTRY}:${IMAGE_TAG}" \
#     --namespace="${ENVIRONMENT}"

# Example: Docker Compose (for simple setups)
# ssh "deploy@${ENVIRONMENT}.example.com" \
#     "cd /app && docker compose pull && docker compose up -d"

log "Deployment initiated for ${ENVIRONMENT} with tag ${IMAGE_TAG}"

# ─────────────────────────────────────────
# Wait for deployment to stabilize
# ─────────────────────────────────────────
log "Waiting for deployment to stabilize..."

# Example: ECS wait
# aws ecs wait services-stable \
#     --cluster "${CLUSTER}" \
#     --services "${SERVICE}"

# Example: Kubernetes wait
# kubectl rollout status deployment/myapp \
#     --namespace="${ENVIRONMENT}" \
#     --timeout=300s

log "Deployment complete!"

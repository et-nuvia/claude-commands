#!/usr/bin/env bash
# =============================================================================
# Deploy Docker Images to Environment
# =============================================================================
# Deploys images to staging or production via SSH (manual) or SSM (CI/CD).
# Reads configuration from PROJECT.yaml via lib/common.sh.
#
# Supports single-repo and multi-repo (docker compose) projects.
#
# Usage:
#   ./deploy.sh --env staging --tag staging-abc1234
#   ./deploy.sh --env staging --tag staging-abc1234 --ssm
#   ./deploy.sh --env production --tag production --ssm --skip-cleanup
# =============================================================================

set -euo pipefail

# Script directory and load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/ecr.sh"

# Defaults
ENVIRONMENT=""
TAG=""
NO_ROTATE=false
SKIP_CLEANUP=false
USE_SSM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --no-rotate) NO_ROTATE=true; shift ;;
    --skip-cleanup) SKIP_CLEANUP=true; shift ;;
    --ssm) USE_SSM=true; shift ;;
    -h|--help)
      echo "Usage: $0 --env <staging|production> --tag <image-tag> [--ssm]"
      echo ""
      echo "Deploys images to EC2 via SSH (default) or SSM (CI/CD)."
      echo ""
      echo "Options:"
      echo "  --env ENV        Target environment (staging|production)"
      echo "  --tag TAG        Docker image tag to deploy"
      echo "  --ssm            Use AWS SSM instead of SSH (for CI/CD)"
      echo "  --no-rotate      Skip ECR tag rotation (used for rollbacks)"
      echo "  --skip-cleanup   Skip ECR cleanup after deployment"
      echo "  -h, --help       Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required args
[[ -z "$ENVIRONMENT" ]] && { echo "Error: --env required (staging|production)"; exit 1; }
[[ -z "$TAG" ]] && { echo "Error: --tag required"; exit 1; }

# Load environment config from PROJECT.yaml
load_config "$ENVIRONMENT"

# Load the appropriate transport helper
if [[ "$USE_SSM" == "true" ]]; then
  source "$SCRIPT_DIR/lib/ssm.sh"
else
  source "$SCRIPT_DIR/lib/ssh.sh"
fi

# Get connection config
if [[ "$USE_SSM" == "true" ]]; then
  INSTANCE_ID=$(get_instance_id "$ENVIRONMENT")
  if [[ -z "$INSTANCE_ID" ]]; then
    echo "Error: No instance ID found for ${ENVIRONMENT}"
    echo "Set ${ENVIRONMENT^^}_INSTANCE_ID or configure deployment.${ENVIRONMENT}.instance_id in PROJECT.yaml"
    exit 1
  fi
else
  ssh_get_config "$ENVIRONMENT" || exit 1
fi

# Get ECR registry
ECR_REGISTRY="${ECR_REGISTRY:-$(ecr_get_registry)}" || exit 1

log_header "Deploying to ${ENVIRONMENT}"
echo "  Tag:          $TAG"
echo "  Deploy Path:  $DEPLOY_PATH"
if [[ "$USE_SSM" == "true" ]]; then
  echo "  Instance:     $INSTANCE_ID"
else
  echo "  Host:         $SSH_HOST"
fi
echo "  Transport:    $(if $USE_SSM; then echo "SSM"; else echo "SSH"; fi)"
echo "  No Rotate:    $NO_ROTATE"
if is_multi_repo 2>/dev/null; then
  echo "  ECR Repos:    $(echo "$ECR_REPOS" | wc -w | tr -d ' ') repos"
fi
echo "═══════════════════════════════════════════════════════════════"

# Test SSH connection (SSH mode only)
if [[ "$USE_SSM" != "true" ]]; then
  echo ""
  ssh_test_connection "$ENVIRONMENT" || exit 1
fi

# Verify image exists in ECR
echo ""
echo "Verifying image exists in ECR..."
if is_multi_repo 2>/dev/null; then
  ecr_verify_tag_all "$TAG" || { echo "Error: Tag ${TAG} not found in all ECR repos"; exit 1; }
else
  ecr_verify_tag "$TAG" || { echo "Error: Tag ${TAG} not found in ECR"; exit 1; }
fi
echo "  Image verified"

# Rotate ECR tags (unless --no-rotate specified, e.g., for rollbacks)
if [[ "$NO_ROTATE" != "true" ]]; then
  echo ""
  if is_multi_repo 2>/dev/null; then
    ecr_rotate_tags_all "$ENVIRONMENT" "$TAG"
  else
    if [[ "$ENVIRONMENT" == "production" ]]; then
      ecr_rotate_production_tags "$TAG"
    else
      ecr_rotate_staging_tags "$TAG"
    fi
  fi
fi

# Detect compose file changes: hash local vs remote, sync if needed
COMPOSE_FILE="${PROJECT_ROOT:-$(pwd)}/docker-compose.yml"
COMPOSE_CHANGED=false

if [[ -f "$COMPOSE_FILE" ]]; then
  LOCAL_HASH=$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')
  echo ""
  echo "Checking compose file (local: ${LOCAL_HASH:0:12}...)"

  HASH_CMD="sha256sum ${DEPLOY_PATH}/docker-compose.yml 2>/dev/null | awk '{print \$1}' || echo 'MISSING'"
  if [[ "$USE_SSM" == "true" ]]; then
    REMOTE_HASH=$(ssm_run_command "$INSTANCE_ID" "$HASH_CMD" 30 2>/dev/null | tail -1 | tr -d '[:space:]') || REMOTE_HASH="MISSING"
  else
    REMOTE_HASH=$(ssh_run_command "$ENVIRONMENT" "$HASH_CMD" 2>/dev/null | tail -1 | tr -d '[:space:]') || REMOTE_HASH="MISSING"
  fi
  echo "  Remote: ${REMOTE_HASH:0:12}..."

  if [[ "$LOCAL_HASH" != "$REMOTE_HASH" ]]; then
    COMPOSE_CHANGED=true
    echo "  Compose file differs — syncing to server"
    COMPOSE_B64=$(base64 < "$COMPOSE_FILE")
    SYNC_CMD="echo '${COMPOSE_B64}' | base64 -d > ${DEPLOY_PATH}/docker-compose.yml"
    if [[ "$USE_SSM" == "true" ]]; then
      ssm_run_command "$INSTANCE_ID" "$SYNC_CMD" 30 || { echo "Error: Failed to sync compose file"; exit 1; }
    else
      ssh_run_command "$ENVIRONMENT" "$SYNC_CMD" || { echo "Error: Failed to sync compose file"; exit 1; }
    fi
    echo "  Compose file synced"
  else
    echo "  Compose file unchanged — skipping sync"
  fi
else
  echo ""
  echo "Warning: No docker-compose.yml found — using existing on server"
fi

# Build deploy command for remote execution
# Phase 1: Pull images (old containers still serving)
# Phase 2: Recreate + health polling
DEPLOY_COMMAND=$(cat <<EOF
set -euo pipefail

cd ${DEPLOY_PATH}

# ── Phase 1: Pull images (old containers still serving) ──────────────

echo '[deploy] Phase 1: Pull images (old containers still serving)'

echo '[deploy] Generating .env...'
cat > .env <<ENVEOF
ENVIRONMENT=${ENVIRONMENT}
REGION=${REGION}
ECR_REGISTRY=${ECR_REGISTRY}
IMAGE_TAG=${TAG}
ENVEOF
echo '[deploy] .env written (ENVIRONMENT=${ENVIRONMENT}, IMAGE_TAG=${TAG})'

echo '[deploy] Logging in to ECR...'
aws ecr get-login-password --region ${REGION} | \
  docker login --username AWS --password-stdin ${ECR_REGISTRY}

echo '[deploy] Cleaning up unused Docker resources...'
docker image prune -f 2>/dev/null || true
docker volume prune -f 2>/dev/null || true
docker builder prune -f --keep-storage=1GB 2>/dev/null || true

echo '[deploy] Recording deployment...'
echo "${TAG} - \$(date) - ${ENVIRONMENT}" >> .deployment-history

echo '[deploy] Pulling images: ${TAG}...'
docker compose pull --quiet

# ── Phase 2: Recreate + health polling ───────────────────────────────

if [[ "${COMPOSE_CHANGED}" == "true" ]]; then
  echo '[deploy] Phase 2: Full restart (compose file changed)'
  docker compose down --timeout 30 --remove-orphans 2>/dev/null || true
  docker compose up -d --remove-orphans
else
  echo '[deploy] Phase 2: Rolling recreate (compose unchanged)'
  docker compose up -d --force-recreate --remove-orphans
fi

echo '[deploy] Polling health (docker compose)...'
HEALTH_TIMEOUT=180
HEALTH_INTERVAL=5
ELAPSED=0

# Get list of services that have health checks
SERVICES_WITH_HEALTH=\$(docker compose ps --format "{{.Name}}" 2>/dev/null || echo "")
ALL_HEALTHY=false

while [ \$ELAPSED -lt \$HEALTH_TIMEOUT ]; do
  UNHEALTHY=0
  for SVC in \$SERVICES_WITH_HEALTH; do
    STATUS=\$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "\$SVC" 2>/dev/null || echo "missing")
    if [[ "\$STATUS" == "healthy" ]] || [[ "\$STATUS" == "no-healthcheck" ]]; then
      continue
    fi
    UNHEALTHY=\$((UNHEALTHY + 1))
  done

  if [[ \$UNHEALTHY -eq 0 ]]; then
    echo "[deploy] All services healthy after \${ELAPSED}s"
    ALL_HEALTHY=true
    break
  fi

  echo "[\${ELAPSED}s] Waiting for health (\${UNHEALTHY} service(s) not ready)..."
  sleep \$HEALTH_INTERVAL
  ELAPSED=\$(( ELAPSED + HEALTH_INTERVAL ))
done

if [[ "\$ALL_HEALTHY" != "true" ]]; then
  echo "[deploy] ERROR: Services did not become healthy within \${HEALTH_TIMEOUT}s"
  docker compose ps
  docker compose logs --tail=80
  exit 1
fi

echo '[deploy] Container status:'
docker compose ps

echo ''
echo '[deploy] Deployment complete!'
EOF
)

# Execute via the appropriate transport
echo ""
echo "Deploying via $(if $USE_SSM; then echo "SSM"; else echo "SSH"; fi)..."

if [[ "$USE_SSM" == "true" ]]; then
  if ! ssm_run_command "$INSTANCE_ID" "$DEPLOY_COMMAND" 300; then
    echo ""
    echo "Error: Deployment failed!"
    exit 1
  fi
else
  if ! ssh_run_command "$ENVIRONMENT" "$DEPLOY_COMMAND"; then
    echo ""
    echo "Error: Deployment failed!"
    exit 1
  fi
fi

# Run cleanup (SSM mode, unless skipped)
if [[ "$USE_SSM" == "true" ]] && [[ "$SKIP_CLEANUP" != "true" ]]; then
  echo ""
  if is_multi_repo 2>/dev/null; then
    ecr_cleanup_all "$ENVIRONMENT"
  else
    ecr_cleanup "$ENVIRONMENT"
  fi
fi

log_header "Deployment Complete"
echo "  Environment: ${ENVIRONMENT}"
echo "  Tag:         ${TAG}"
echo "═══════════════════════════════════════════════════════════════"

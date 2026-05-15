#!/usr/bin/env bash
# run-migrations.sh
# Runs database migrations in a short-lived container before deployment
#
# Best Practice Pattern:
# 1. Pull the NEW image (contains latest migration files)
# 2. Run migrations in a temporary container
# 3. If successful, proceed with deployment
# 4. If failed, abort deployment (old containers keep running)
#
# Usage: ./scripts/run-migrations.sh --image <image> [--environment <env>]
# Example: ./scripts/run-migrations.sh --image myapp:v1.2.0 --environment staging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"

require_project_config

# Arguments
IMAGE=""
ENVIRONMENT="${ENVIRONMENT:-staging}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)       IMAGE="$2";       shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --image <image> [--environment <env>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$IMAGE" ]]; then
    echo "Usage: $0 --image <image> [--environment <env>]"
    echo "Example: $0 --image myapp:v1.2.0 --environment staging"
    exit 1
fi

# Configuration from PROJECT.yaml
APP_NAME=$(get_app_name)
MIGRATIONS_ENABLED=$(get_config '.migrations.enabled' 'false')
MIGRATION_CMD=$(get_config '.migrations.command' '')
MIGRATION_TIMEOUT=$(get_config '.migrations.timeout' '300')
HEALTH_CHECK_ENABLED=$(get_config '.migrations.health_check.enabled' 'true')
HEALTH_CHECK_CMD=$(get_config '.migrations.health_check.command' '')
SECRETS_BACKEND=$(get_secrets_backend)

echo "=============================================="
echo "Database Migration Runner"
echo "=============================================="
echo "App:         ${APP_NAME}"
echo "Image:       ${IMAGE}"
echo "Environment: ${ENVIRONMENT}"
echo "=============================================="

# Check if migrations are enabled
if [[ "$MIGRATIONS_ENABLED" != "true" ]]; then
    echo "Migrations not enabled in PROJECT.yaml (migrations.enabled: false)"
    echo "Skipping migration step."
    exit 0
fi

# Check migration command is configured
if [[ -z "$MIGRATION_CMD" || "$MIGRATION_CMD" == "null" ]]; then
    echo "Error: No migration command configured in PROJECT.yaml"
    echo "Set migrations.command to your migration command, e.g.:"
    echo "  migrations:"
    echo "    command: \"alembic upgrade head\""
    exit 1
fi

echo "Migration command: ${MIGRATION_CMD}"
echo ""

# Build environment variables for the container
ENV_ARGS="-e ENVIRONMENT=${ENVIRONMENT}"

if [[ "$SECRETS_BACKEND" == "aws" ]]; then
    ENV_ARGS="${ENV_ARGS} -e REGION=${REGION:-us-east-1}"
    # For AWS, we might need to pass credentials or use IAM role
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        ENV_ARGS="${ENV_ARGS} -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
        ENV_ARGS="${ENV_ARGS} -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
        ENV_ARGS="${ENV_ARGS} -e AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:-}"
    fi
else
    # Infisical
    ENV_ARGS="${ENV_ARGS} -e INFISICAL_SECRET=${INFISICAL_SECRET:-}"
    ENV_ARGS="${ENV_ARGS} -e INFISICAL_PROJECT_ID=${INFISICAL_PROJECT_ID:-}"
fi

# Step 1: Pre-migration health check
if [[ "$HEALTH_CHECK_ENABLED" == "true" ]]; then
    echo "Running pre-migration health check..."

    if [[ -n "$HEALTH_CHECK_CMD" && "$HEALTH_CHECK_CMD" != "null" ]]; then
        HEALTH_CMD="$HEALTH_CHECK_CMD"
    else
        # Auto-detect based on common patterns
        HEALTH_CMD="echo 'No health check command configured, skipping'"
    fi

    echo "Health check: ${HEALTH_CMD}"

    if ! timeout 30 docker run --rm \
        ${ENV_ARGS} \
        --network host \
        "${IMAGE}" \
        sh -c "${HEALTH_CMD}"; then
        echo ""
        echo "ERROR: Pre-migration health check failed!"
        echo "Database may not be reachable. Aborting migration."
        exit 1
    fi

    echo "Health check passed."
    echo ""
fi

# Step 2: Run migrations
echo "Running migrations..."
echo "Timeout: ${MIGRATION_TIMEOUT} seconds"
echo ""

# Create a temporary container name for tracking
CONTAINER_NAME="migration-${APP_NAME}-$(date +%s)"

# Run migration in a container
# - Use --rm to auto-cleanup
# - Use network=host or appropriate network for DB access
# - Mount PROJECT.yaml if needed by the migration command
MIGRATION_EXIT_CODE=0

timeout "${MIGRATION_TIMEOUT}" docker run \
    --rm \
    --name "${CONTAINER_NAME}" \
    ${ENV_ARGS} \
    --network host \
    -v "$(pwd)/PROJECT.yaml:/app/PROJECT.yaml:ro" \
    "${IMAGE}" \
    sh -c "${MIGRATION_CMD}" || MIGRATION_EXIT_CODE=$?

echo ""

if [[ $MIGRATION_EXIT_CODE -eq 0 ]]; then
    echo "=============================================="
    echo "MIGRATIONS COMPLETED SUCCESSFULLY"
    echo "=============================================="
    echo "Proceeding with deployment..."
    exit 0
elif [[ $MIGRATION_EXIT_CODE -eq 124 ]]; then
    echo "=============================================="
    echo "MIGRATION TIMEOUT"
    echo "=============================================="
    echo "Migration exceeded ${MIGRATION_TIMEOUT} second timeout."
    echo "Check for long-running migrations or database locks."
    echo "Deployment ABORTED."
    exit 1
else
    echo "=============================================="
    echo "MIGRATION FAILED (exit code: ${MIGRATION_EXIT_CODE})"
    echo "=============================================="
    echo "Database may be in an inconsistent state."
    echo "Review migration logs above."
    echo "Deployment ABORTED."
    exit 1
fi

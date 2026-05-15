#!/usr/bin/env bash
# =============================================================================
# Run Database Migrations on Remote Environment
# =============================================================================
# Runs DB migrations via docker compose run on a temporary container.
# Reads migration config from PROJECT.yaml.
# Supports SSH (manual) and SSM (CI/CD) transports.
#
# Usage:
#   ./migrate.sh --env staging
#   ./migrate.sh --env production --ssm
# =============================================================================

set -euo pipefail

# Script directory
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
      echo "Runs database migrations via temporary container."
      echo ""
      echo "Options:"
      echo "  --env ENV    Target environment (staging|production)"
      echo "  --ssm        Use AWS SSM instead of SSH (for CI/CD)"
      echo "  -h, --help   Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate
[[ -z "$ENVIRONMENT" ]] && { echo "Error: --env required (staging|production)"; exit 1; }

# Load environment config
load_config "$ENVIRONMENT"

# Read migration config from PROJECT.yaml
MIGRATION_TOOL=$(_yaml_get '.databases[0].migrations.tool' 'typeorm')
MIGRATION_SERVICE=$(_yaml_get '.databases[0].migrations.service' '')
if [[ -z "$MIGRATION_SERVICE" ]]; then
  # Default to first component path (typically the service with the DB)
  MIGRATION_SERVICE=$(_yaml_get '.components[0].path' 'backend')
fi

# Load the appropriate transport helper
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

log_header "Running Migrations (${ENVIRONMENT})"

# Build migration command based on tool type
case "$MIGRATION_TOOL" in
  typeorm)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} npm run migration:run"
    ;;
  alembic)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} alembic upgrade head"
    ;;
  prisma)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} npx prisma migrate deploy"
    ;;
  knex)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} npx knex migrate:latest"
    ;;
  django)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} python manage.py migrate"
    ;;
  goose)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} goose up"
    ;;
  manual)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} node scripts/run-all-migrations.js"
    ;;
  *)
    MIGRATE_CMD="docker compose run --rm ${MIGRATION_SERVICE} npm run migration:run"
    ;;
esac

MIGRATE_COMMAND=$(cat <<EOF
set -euo pipefail

cd ${DEPLOY_PATH}

# Source .env to get ECR_REGISTRY and IMAGE_TAG
set -a
source .env
set +a

echo "[migrate] Running database migrations (${MIGRATION_TOOL})..."
${MIGRATE_CMD}
echo "[migrate] Migrations complete"
EOF
)

if [[ "$USE_SSM" == "true" ]]; then
  if ! ssm_run_command "$INSTANCE_ID" "$MIGRATE_COMMAND" 120; then
    echo "Error: Migration failed!"
    exit 1
  fi
else
  if ! ssh_run_command "$ENVIRONMENT" "$MIGRATE_COMMAND"; then
    echo "Error: Migration failed!"
    exit 1
  fi
fi

log_header "Migrations Complete"

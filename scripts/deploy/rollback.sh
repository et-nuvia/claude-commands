#!/usr/bin/env bash
# =============================================================================
# Rollback to Previous Deployment
# =============================================================================
# Rolls back to a previous deployment using ECR tags.
# Supports single-repo and multi-repo projects.
#
# Usage:
#   ./rollback.sh --env staging               # Rollback to previous-1
#   ./rollback.sh --env staging --steps 3     # Rollback to previous-3
#   ./rollback.sh --env production --ssm      # CI/CD rollback via SSM
#   ./rollback.sh --env staging --tag abc123  # Rollback to specific tag
# =============================================================================

set -euo pipefail

# Script directory and load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/ecr.sh"

# Defaults
ENVIRONMENT=""
TAG=""
STEPS=1
FORCE=false
USE_SSM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --force|-f) FORCE=true; shift ;;
    --ssm) USE_SSM=true; shift ;;
    -h|--help)
      echo "Usage: $0 --env <staging|production> [--steps N | --tag TAG] [--ssm]"
      echo ""
      echo "Rolls back to a previous deployment."
      echo ""
      echo "Options:"
      echo "  --env ENV      Target environment (staging|production)"
      echo "  --steps N      Rollback N versions (default: 1, max: 4)"
      echo "  --tag TAG      Rollback to specific tag"
      echo "  --ssm          Use AWS SSM instead of SSH (for CI/CD)"
      echo "  --force, -f    Skip confirmation prompt"
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

# Determine rollback tag if not specified
ROLLBACK_TAG=""
if [[ -z "$TAG" ]]; then
  MAX_STEPS=4
  if [[ "$STEPS" -gt "$MAX_STEPS" ]]; then
    echo "Error: Max rollback steps is ${MAX_STEPS}"
    exit 1
  fi
  ROLLBACK_TAG="${ENVIRONMENT}-previous-${STEPS}"

  log_header "Rollback ${ENVIRONMENT}"
  echo "  Looking up: ${ROLLBACK_TAG}"
  echo "═══════════════════════════════════════════════════════════════"

  # Verify the rollback tag exists
  if is_multi_repo 2>/dev/null; then
    if ! ecr_verify_tag_all "$ROLLBACK_TAG"; then
      echo ""
      echo "Error: ${ROLLBACK_TAG} not found in all ECR repos"
      exit 1
    fi
  else
    if ! ecr_tag_exists "$ROLLBACK_TAG"; then
      echo ""
      echo "Error: No image found with tag ${ROLLBACK_TAG}"
      echo ""
      ecr_list_previous_tags "$ENVIRONMENT"
      exit 1
    fi
  fi

  TAG="$ROLLBACK_TAG"
  echo "  Found: ${TAG}"
else
  log_header "Rollback ${ENVIRONMENT}"
  echo "  Using specified tag: ${TAG}"
  echo "═══════════════════════════════════════════════════════════════"

  if is_multi_repo 2>/dev/null; then
    ecr_verify_tag_all "$TAG" || { echo "Error: Tag ${TAG} not found in all repos"; exit 1; }
  else
    ecr_verify_tag "$TAG" || { echo "Error: Tag ${TAG} not found in ECR"; exit 1; }
  fi
fi

echo ""
echo "Rolling back ${ENVIRONMENT} to ${TAG}..."

# Confirm rollback (unless --force)
if [[ "$FORCE" != "true" ]]; then
  read -p "Are you sure you want to rollback? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Rollback cancelled"
    exit 0
  fi
fi

# Restore the rollback tag
echo ""
echo "Restoring ECR tags..."
if is_multi_repo 2>/dev/null; then
  ecr_restore_all "$ENVIRONMENT" "$STEPS"
else
  if [[ "$ENVIRONMENT" == "production" ]]; then
    ecr_restore_production_previous "$STEPS"
  else
    ecr_restore_staging_previous "$STEPS"
  fi
fi

# Deploy the rollback tag (without rotating tags)
echo ""
DEPLOY_ARGS=("--env" "${ENVIRONMENT}" "--tag" "${TAG}" "--no-rotate")
[[ "$USE_SSM" == "true" ]] && DEPLOY_ARGS+=("--ssm")
"$SCRIPT_DIR/deploy.sh" "${DEPLOY_ARGS[@]}"

log_header "Rollback Complete"
echo "  ${ENVIRONMENT} is now running ${TAG}"
echo "═══════════════════════════════════════════════════════════════"

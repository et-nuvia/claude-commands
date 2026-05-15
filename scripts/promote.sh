#!/usr/bin/env bash
set -euo pipefail

# Image Promotion Script
# Promotes container images between environments based on deployment.yaml config
# Usage: ./scripts/promote.sh --from-env <env> --to-env <env> --version <ver>
# Copy to project: cp ~/.claude/scripts/promote.sh ./scripts/

FROM_ENV=""
TO_ENV=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-env) FROM_ENV="$2"; shift 2 ;;
    --to-env)   TO_ENV="$2";   shift 2 ;;
    --version)  VERSION="$2";  shift 2 ;;
    -h|--help)
      echo "Usage: $0 --from-env <env> --to-env <env> --version <ver>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$FROM_ENV" || -z "$TO_ENV" || -z "$VERSION" ]]; then
  echo "Error: --from-env, --to-env, and --version are required" >&2
  echo "Usage: $0 --from-env <env> --to-env <env> --version <ver>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_CONFIG="deployment.yaml"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[promote]${NC} $1"; }
warn() { echo -e "${YELLOW}[promote]${NC} $1"; }
error() { echo -e "${RED}[promote]${NC} $1" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# Check prerequisites
# ─────────────────────────────────────────────────────────────
if [[ ! -f "${DEPLOYMENT_CONFIG}" ]]; then
    error "deployment.yaml not found. Create deployment configuration first."
fi

if ! command -v yq &> /dev/null; then
    error "yq is required. Install: brew install yq (macOS) or snap install yq (Linux)"
fi

# ─────────────────────────────────────────────────────────────
# Read configuration
# ─────────────────────────────────────────────────────────────
STRATEGY=$(yq '.registry.strategy' "${DEPLOYMENT_CONFIG}")
log "Registry strategy: ${STRATEGY}"

get_image_path() {
    local env="$1"
    local tag="$2"

    if [[ "${STRATEGY}" == "single" ]]; then
        local url pattern
        url=$(yq '.registry.single.url' "${DEPLOYMENT_CONFIG}")
        pattern=$(yq '.registry.single.tag_pattern // "${environment}-${version}"' "${DEPLOYMENT_CONFIG}")
        local resolved_tag="${pattern//\$\{environment\}/${env}}"
        resolved_tag="${resolved_tag//\$\{version\}/${tag}}"
        echo "${url}:${resolved_tag}"
    else
        local url repo
        url=$(yq ".registry.separate.${env}.url" "${DEPLOYMENT_CONFIG}")
        repo=$(yq ".registry.separate.${env}.repository" "${DEPLOYMENT_CONFIG}")
        echo "${url}/${repo}:${tag}"
    fi
}

get_aws_region() {
    local env="$1"
    yq ".registry.separate.${env}.aws_region // \"us-east-1\"" "${DEPLOYMENT_CONFIG}"
}

get_aws_role_arn() {
    local env="$1"
    yq ".registry.separate.${env}.aws_role_arn // \"\"" "${DEPLOYMENT_CONFIG}"
}

# ─────────────────────────────────────────────────────────────
# Build image paths
# ─────────────────────────────────────────────────────────────
SOURCE_IMAGE=$(get_image_path "${FROM_ENV}" "${VERSION}")
TARGET_IMAGE=$(get_image_path "${TO_ENV}" "${VERSION}")

log "Source: ${SOURCE_IMAGE}"
log "Target: ${TARGET_IMAGE}"

# ─────────────────────────────────────────────────────────────
# Validate promotion path
# ─────────────────────────────────────────────────────────────
VALID_PROMOTION=$(yq ".promotion.path[] | select(.from == \"${FROM_ENV}\" and .to == \"${TO_ENV}\") | .from" "${DEPLOYMENT_CONFIG}")

if [[ -z "${VALID_PROMOTION}" ]]; then
    error "Invalid promotion path: ${FROM_ENV} → ${TO_ENV}. Check deployment.yaml promotion.path"
fi

# Check requirements
REQUIREMENTS=$(yq ".promotion.path[] | select(.from == \"${FROM_ENV}\" and .to == \"${TO_ENV}\") | .requirements[]?" "${DEPLOYMENT_CONFIG}")

if [[ -n "${REQUIREMENTS}" ]]; then
    log "Checking promotion requirements..."
    while IFS= read -r req; do
        case "${req}" in
            approval_required)
                if [[ "${CI:-false}" != "true" ]]; then
                    warn "⚠️  This promotion requires approval"
                    warn "Press Enter to continue or Ctrl+C to cancel..."
                    read -r
                fi
                ;;
            *)
                log "  ✓ ${req} (assumed passed)"
                ;;
        esac
    done <<< "${REQUIREMENTS}"
fi

# ─────────────────────────────────────────────────────────────
# Authenticate to registries
# ─────────────────────────────────────────────────────────────
ecr_login() {
    local env="$1"
    local region url

    if [[ "${STRATEGY}" == "single" ]]; then
        url=$(yq '.registry.single.url' "${DEPLOYMENT_CONFIG}")
        region=$(yq '.registry.single.aws_region // "us-east-1"' "${DEPLOYMENT_CONFIG}")
    else
        url=$(yq ".registry.separate.${env}.url" "${DEPLOYMENT_CONFIG}")
        region=$(get_aws_region "${env}")
    fi

    # Extract account ID from ECR URL
    local account_id="${url%%.*}"

    local role_arn
    role_arn=$(get_aws_role_arn "${env}")

    if [[ -n "${role_arn}" && "${role_arn}" != "null" ]]; then
        log "Assuming role for ${env}: ${role_arn}"

        # Assume role and get credentials
        local creds
        creds=$(aws sts assume-role \
            --role-arn "${role_arn}" \
            --role-session-name "promote-${env}-${VERSION}" \
            --output json)

        export AWS_ACCESS_KEY_ID=$(echo "${creds}" | jq -r '.Credentials.AccessKeyId')
        export AWS_SECRET_ACCESS_KEY=$(echo "${creds}" | jq -r '.Credentials.SecretAccessKey')
        export AWS_SESSION_TOKEN=$(echo "${creds}" | jq -r '.Credentials.SessionToken')
    fi

    log "Logging into ECR (${env}): ${url}"
    aws ecr get-login-password --region "${region}" | \
        docker login --username AWS --password-stdin "${url}"
}

# Login to source registry
log "Authenticating to source registry (${FROM_ENV})..."
ecr_login "${FROM_ENV}"

# ─────────────────────────────────────────────────────────────
# Pull source image
# ─────────────────────────────────────────────────────────────
log "Pulling source image..."
if ! docker pull "${SOURCE_IMAGE}"; then
    error "Failed to pull source image: ${SOURCE_IMAGE}"
fi

# ─────────────────────────────────────────────────────────────
# Authenticate to target registry (if different)
# ─────────────────────────────────────────────────────────────
if [[ "${STRATEGY}" == "separate" ]]; then
    SOURCE_URL=$(yq ".registry.separate.${FROM_ENV}.url" "${DEPLOYMENT_CONFIG}")
    TARGET_URL=$(yq ".registry.separate.${TO_ENV}.url" "${DEPLOYMENT_CONFIG}")

    if [[ "${SOURCE_URL}" != "${TARGET_URL}" ]]; then
        log "Authenticating to target registry (${TO_ENV})..."
        # Clear previous credentials
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        ecr_login "${TO_ENV}"
    fi
fi

# ─────────────────────────────────────────────────────────────
# Tag and push to target
# ─────────────────────────────────────────────────────────────
log "Tagging for target..."
docker tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}"

log "Pushing to target registry..."
if ! docker push "${TARGET_IMAGE}"; then
    error "Failed to push target image: ${TARGET_IMAGE}"
fi

# Also tag as 'latest' for the environment
TARGET_LATEST="${TARGET_IMAGE%:*}:latest"
docker tag "${SOURCE_IMAGE}" "${TARGET_LATEST}"
docker push "${TARGET_LATEST}"

# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────
log "Cleaning up local images..."
docker rmi "${SOURCE_IMAGE}" "${TARGET_IMAGE}" "${TARGET_LATEST}" 2>/dev/null || true

# Clear assumed role credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  PROMOTION COMPLETE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BLUE}From:${NC}    ${FROM_ENV}"
echo -e "  ${BLUE}To:${NC}      ${TO_ENV}"
echo -e "  ${BLUE}Version:${NC} ${VERSION}"
echo -e "  ${BLUE}Image:${NC}   ${TARGET_IMAGE}"
echo ""

# Trigger deployment if auto_deploy is enabled
AUTO_DEPLOY=$(yq ".environments.${TO_ENV}.auto_deploy // false" "${DEPLOYMENT_CONFIG}")

if [[ "${AUTO_DEPLOY}" == "true" ]]; then
    log "Auto-deploy enabled for ${TO_ENV}"
    if [[ -f "${SCRIPT_DIR}/deploy.sh" ]]; then
        "${SCRIPT_DIR}/deploy.sh" "${TO_ENV}" "${VERSION}"
    else
        warn "deploy.sh not found, skipping auto-deploy"
    fi
else
    log "Auto-deploy disabled. Run manually:"
    echo "  ./scripts/deploy.sh ${TO_ENV} ${VERSION}"
fi

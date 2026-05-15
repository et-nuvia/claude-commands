#!/usr/bin/env bash
# =============================================================================
# Build and Push Docker Images to ECR
# =============================================================================
# Builds Docker image(s) and pushes to AWS ECR.
# For multi-service projects (docker compose), builds all services.
# For single-service projects, builds a single image.
#
# Usage:
#   ./build-and-push.sh                      # Auto-generate tag from git SHA
#   ./build-and-push.sh --tag my-tag         # Use specific tag
#   ./build-and-push.sh --env staging        # Build for staging
#   ./build-and-push.sh --skip-push          # Build only, don't push
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/version.sh"
source "$SCRIPT_DIR/lib/ecr.sh"

# Load project config (no environment needed for build)
load_project

# Defaults
TAG=""
ENVIRONMENT=""
SKIP_PUSH=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --tag) TAG="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --skip-push) SKIP_PUSH=true; shift ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --tag TAG        Image tag (default: git-sha-timestamp)"
      echo "  --env ENV        Target environment (staging|production)"
      echo "  --skip-push      Build only, don't push to ECR"
      echo "  -h, --help       Show this help"
      echo ""
      echo "Current version: $(version_get_current)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# If environment specified, load its config for ECR_REGISTRY
if [[ -n "$ENVIRONMENT" ]]; then
  load_config "$ENVIRONMENT"
fi

# Get version and git info
VERSION=$(version_get_current)
BUILD_VERSION=$(version_get_build_string)
GIT_SHA=$(git -C "${PROJECT_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Generate tag if not specified
if [[ -z "$TAG" ]]; then
  if [[ -n "$ENVIRONMENT" ]]; then
    TAG="${ENVIRONMENT}-${GIT_SHA}-${TIMESTAMP}"
  else
    TAG="${GIT_SHA}-${TIMESTAMP}"
  fi
fi

# Get ECR registry
ECR_REGISTRY="${ECR_REGISTRY:-$(ecr_get_registry)}" || exit 1

log_header "Building Docker Image(s)"
echo "  Project:      ${PROJECT_NAME:-unknown}"
echo "  Version:      $VERSION"
echo "  Build:        $BUILD_VERSION"
echo "  Git SHA:      $GIT_SHA"
echo "  ECR Registry: $ECR_REGISTRY"
echo "  Tag:          $TAG"
if [[ -n "$ENVIRONMENT" ]]; then
  echo "  Environment:  $ENVIRONMENT"
fi
if is_multi_repo 2>/dev/null; then
  echo "  ECR Repos:    $(echo "$ECR_REPOS" | wc -w | tr -d ' ') repos"
fi
echo "═══════════════════════════════════════════════════════════════"

# Ensure ECR repositories exist
echo ""
if is_multi_repo 2>/dev/null; then
  ecr_ensure_repos_all
else
  ecr_ensure_repo
fi

# Login to ECR
echo ""
ecr_login || exit 1

cd "${PROJECT_ROOT:-.}"

# Build and push
if is_multi_repo 2>/dev/null; then
  # Multi-service: use docker compose build
  echo ""
  echo "Building all services via docker compose..."

  # Set image tags in environment for docker compose
  export IMAGE_TAG="$TAG"
  export ECR_REGISTRY

  if [[ "$SKIP_PUSH" == "true" ]]; then
    docker compose build \
      --build-arg BUILD_VERSION="$BUILD_VERSION" \
      --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --build-arg VCS_REF="$GIT_SHA"
    echo "Docker images built (not pushed)"
  else
    docker compose build \
      --build-arg BUILD_VERSION="$BUILD_VERSION" \
      --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --build-arg VCS_REF="$GIT_SHA"

    # Tag and push each service
    for repo in $ECR_REPOS; do
      local_svc=$(basename "$repo")  # e.g., "backend" from "nuvia/n1-consult/backend"
      full_image="${ECR_REGISTRY}/${repo}:${TAG}"

      echo ""
      echo "Tagging and pushing ${local_svc}..."
      docker tag "${PROJECT_NAME}-${local_svc}:latest" "$full_image" 2>/dev/null || \
        docker tag "${local_svc}:latest" "$full_image" 2>/dev/null || \
        echo "Warning: Could not find local image for ${local_svc}"
      docker push "$full_image"

      if [[ -n "$ENVIRONMENT" ]]; then
        env_image="${ECR_REGISTRY}/${repo}:${ENVIRONMENT}"
        docker tag "$full_image" "$env_image"
        docker push "$env_image"
      fi
    done
    echo "All images pushed"
  fi
else
  # Single-service: use docker buildx directly
  local_repo="${ECR_REPOS:-${ECR_PROJECT}}"
  FULL_IMAGE="${ECR_REGISTRY}/${local_repo}:${TAG}"

  TAGS=("-t" "$FULL_IMAGE")
  if [[ -n "$ENVIRONMENT" ]]; then
    TAGS+=("-t" "${ECR_REGISTRY}/${local_repo}:${ENVIRONMENT}")
  fi

  echo ""
  echo "Building Docker image for linux/amd64..."

  BUILD_ARGS=(
    --platform linux/amd64
    --build-arg "BUILD_VERSION=$BUILD_VERSION"
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --build-arg "VCS_REF=$GIT_SHA"
    --build-arg "VCS_BRANCH=$(git -C "${PROJECT_ROOT:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  )

  if [[ "$SKIP_PUSH" == "true" ]]; then
    docker buildx build "${BUILD_ARGS[@]}" "${TAGS[@]}" .
    echo "Docker image built (not pushed)"
  else
    docker buildx build --no-cache "${BUILD_ARGS[@]}" "${TAGS[@]}" --push .
    echo "Docker image built and pushed"
  fi
fi

log_header "Build Complete"
echo "  Version: $BUILD_VERSION"
echo "  Tag:     $TAG"
echo "═══════════════════════════════════════════════════════════════"

# Output for scripts/CI
echo ""
echo "BUILD_TAG=${TAG}"
echo "BUILD_VERSION=${BUILD_VERSION}"

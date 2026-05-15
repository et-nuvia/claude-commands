#!/bin/bash
# =============================================================================
# Common Configuration Loader
# =============================================================================
# Shared config loader that all deploy scripts source. Reads PROJECT.yaml
# to export standard variables, replacing hardcoded project-specific values.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#   load_config staging    # Load environment-specific config
#
# After load_config:
#   PROJECT_NAME       - Project name (e.g., "n1-consult")
#   PROJECT_ROOT       - Absolute path to project root (where PROJECT.yaml lives)
#   ECR_REGISTRY       - ECR registry URL (e.g., "553338498219.dkr.ecr.us-west-1.amazonaws.com")
#   ECR_REGION         - AWS region for ECR (e.g., "us-west-1")
#   ECR_REPOS          - Array of ECR repo names (e.g., "nuvia/n1-consult/backend nuvia/n1-consult/frontend nuvia/n1-consult/ai")
#   DEPLOY_PATH        - Remote deploy path (e.g., "/opt/nuvia/n1-consult")
#   DEPLOY_URL         - Base URL for health checks (e.g., "http://52.52.125.244")
#   HEALTH_CHECK_PATH  - Health endpoint path (e.g., "/health")
#   VERSION_PATH       - Version endpoint path (e.g., "/api/version")
#   INSTANCE_ID        - EC2 instance ID for SSM commands
#   REGION             - AWS region for the environment
#   COMPOSE_SERVICES   - Space-separated list of buildable docker services
#   DEPLOY_ENVIRONMENT - Current environment (staging|production)
# =============================================================================

# Guard against double-sourcing
if [[ "${_COMMON_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_COMMON_SH_LOADED="true"

# =============================================================================
# _find_project_root - Walk up directory tree to find PROJECT.yaml
# =============================================================================
_find_project_root() {
  local dir="${1:-$(pwd)}"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/PROJECT.yaml" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

# =============================================================================
# _yaml_get - Read a value from PROJECT.yaml using yq
# =============================================================================
# Arguments:
#   $1 - yq expression (e.g., '.name', '.deployment.staging.url')
#   $2 - (optional) default value if field is missing/null
# =============================================================================
_yaml_get() {
  local expr="$1"
  local default="${2:-}"
  local value

  if [[ -z "${PROJECT_ROOT:-}" ]] || [[ ! -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
    echo "$default"
    return
  fi

  value=$(yq eval "$expr // \"\"" "${PROJECT_ROOT}/PROJECT.yaml" 2>/dev/null || echo "")

  if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# =============================================================================
# _yaml_get_array - Read an array from PROJECT.yaml, one item per line
# =============================================================================
_yaml_get_array() {
  local expr="$1"

  if [[ -z "${PROJECT_ROOT:-}" ]] || [[ ! -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
    return
  fi

  yq eval "${expr}" "${PROJECT_ROOT}/PROJECT.yaml" 2>/dev/null | grep -v '^---$' || true
}

# =============================================================================
# load_project - Load project-level config (no environment needed)
# =============================================================================
# Sets: PROJECT_NAME, PROJECT_ROOT, HEALTH_CHECK_PATH, VERSION_PATH, COMPOSE_SERVICES
# =============================================================================
load_project() {
  # Find project root — try pwd first (most reliable when sourced),
  # then fall back to caller script directory
  if [[ -z "${PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT=$(_find_project_root "$(pwd)") || {
      local script_dir
      script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
      PROJECT_ROOT=$(_find_project_root "$script_dir") || {
        echo "Warning: PROJECT.yaml not found. Using environment variables." >&2
        return 0
      }
    }
  fi

  export PROJECT_ROOT

  # Project identity
  PROJECT_NAME="${PROJECT_NAME:-$(_yaml_get '.name')}"
  export PROJECT_NAME

  # Health check paths
  HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-$(_yaml_get '.deployment.health_check_path' '/health')}"
  VERSION_PATH="${VERSION_PATH:-$(_yaml_get '.deployment.version_path' '/api/version')}"
  export HEALTH_CHECK_PATH VERSION_PATH

  # Docker services that can be built (have a Dockerfile)
  if [[ -z "${COMPOSE_SERVICES:-}" ]]; then
    local services=""
    local components
    components=$(_yaml_get_array '.components[].path')
    while IFS= read -r component; do
      if [[ -n "$component" ]] && [[ -f "${PROJECT_ROOT}/${component}/Dockerfile" ]]; then
        services="${services:+$services }${component}"
      fi
    done <<< "$components"
    COMPOSE_SERVICES="${services:-}"
  fi
  export COMPOSE_SERVICES
}

# =============================================================================
# load_config - Load environment-specific config
# =============================================================================
# Arguments:
#   $1 - Environment: staging or production
#
# Sets all variables from load_project plus environment-specific ones:
#   ECR_REGISTRY, ECR_REGION, ECR_REPOS, DEPLOY_PATH, DEPLOY_URL,
#   INSTANCE_ID, REGION, DEPLOY_ENVIRONMENT
# =============================================================================
load_config() {
  local environment="${1:-}"

  if [[ -z "$environment" ]]; then
    echo "Error: Environment required (staging|production)" >&2
    return 1
  fi

  DEPLOY_ENVIRONMENT="$environment"
  export DEPLOY_ENVIRONMENT

  # Load project-level config first
  load_project

  # AWS region
  REGION="${REGION:-$(_yaml_get ".deployment.${environment}.region" 'us-west-1')}"
  export REGION

  # ECR registry — check environment-specific first, then global docker.registry
  if [[ -z "${ECR_REGISTRY:-}" ]]; then
    ECR_REGISTRY=$(_yaml_get ".docker.environments.${environment}.registry")
    if [[ -z "$ECR_REGISTRY" ]]; then
      # Construct from account ID + region if docker.registry.type is ecr
      local registry_type
      registry_type=$(_yaml_get '.docker.registry.type')
      local registry_region
      registry_region=$(_yaml_get '.docker.registry.region' "$REGION")
      if [[ "$registry_type" == "ecr" ]] && [[ -n "$ECR_REGISTRY" || -n "${AWS_ACCOUNT_ID:-}" ]]; then
        # Try to get account ID from existing registry or AWS CLI
        local account_id="${AWS_ACCOUNT_ID:-}"
        if [[ -z "$account_id" ]]; then
          account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
        fi
        if [[ -n "$account_id" ]]; then
          ECR_REGISTRY="${account_id}.dkr.ecr.${registry_region}.amazonaws.com"
        fi
      fi
    fi
  fi
  ECR_REGION="${ECR_REGION:-${REGION}}"
  export ECR_REGISTRY ECR_REGION

  # ECR repos — build from docker.registry.repo (single-repo) or components (multi-repo)
  if [[ -z "${ECR_REPOS:-}" ]]; then
    local single_repo
    single_repo=$(_yaml_get '.docker.registry.repo')

    if [[ -n "$single_repo" ]]; then
      # Single-repo project (e.g., intake-form: "nuvia/intake-form")
      ECR_REPOS="$single_repo"
    elif [[ -n "$COMPOSE_SERVICES" ]]; then
      # Multi-repo project: construct from ecr_namespace + project name + service names
      # e.g., n1-consult with backend/frontend/ai -> nuvia/n1-consult/backend nuvia/n1-consult/frontend nuvia/n1-consult/ai
      local ecr_namespace
      ecr_namespace=$(_yaml_get '.docker.ecr_namespace' '')
      local repos=""
      for svc in $COMPOSE_SERVICES; do
        if [[ -n "$ecr_namespace" ]]; then
          repos="${repos:+$repos }${ecr_namespace}/${PROJECT_NAME}/${svc}"
        else
          repos="${repos:+$repos }${PROJECT_NAME}/${svc}"
        fi
      done
      ECR_REPOS="$repos"
    fi
  fi
  export ECR_REPOS

  # Deploy path on remote server
  DEPLOY_PATH="${DEPLOY_PATH:-$(_yaml_get ".deployment.${environment}.path")}"
  if [[ -z "$DEPLOY_PATH" ]]; then
    echo "Warning: deployment.${environment}.path not set in PROJECT.yaml and DEPLOY_PATH not provided" >&2
  fi
  export DEPLOY_PATH

  # Deploy URL for health checks
  DEPLOY_URL="${DEPLOY_URL:-$(_yaml_get ".deployment.${environment}.url")}"
  export DEPLOY_URL

  # EC2 instance ID for SSM
  INSTANCE_ID="${INSTANCE_ID:-$(_yaml_get ".deployment.${environment}.instance_id")}"
  export INSTANCE_ID
}

# =============================================================================
# get_ecr_repos - Get list of ECR repos as an array
# =============================================================================
# Returns repo names one per line. Use in loops:
#   while read -r repo; do ... done <<< "$(get_ecr_repos)"
# =============================================================================
get_ecr_repos() {
  echo "$ECR_REPOS" | tr ' ' '\n'
}

# =============================================================================
# get_compose_services - Get list of buildable services as an array
# =============================================================================
get_compose_services() {
  echo "$COMPOSE_SERVICES" | tr ' ' '\n'
}

# =============================================================================
# is_multi_repo - Check if project has multiple ECR repos
# =============================================================================
is_multi_repo() {
  local count
  count=$(echo "$ECR_REPOS" | wc -w | tr -d ' ')
  [[ "$count" -gt 1 ]]
}

# =============================================================================
# log helpers
# =============================================================================
log_info() {
  echo "  $*"
}

log_success() {
  echo "  ✓ $*"
}

log_warn() {
  echo "  ⚠ $*" >&2
}

log_error() {
  echo "  ✗ $*" >&2
}

log_header() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════"
}

log_step() {
  echo ""
  echo "── $* ──"
}

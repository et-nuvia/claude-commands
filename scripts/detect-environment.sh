#!/usr/bin/env bash
# Environment Detection Script
# Detects home vs work environment and provides PROJECT.yaml information

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_error() { echo -e "${RED}✗ $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}" >&2; }
print_info() { echo -e "${BLUE}ℹ $1${NC}" >&2; }

# Function to detect environment based on OS
detect_environment() {
  local os
  os=$(uname -s)

  case "$os" in
    Darwin)
      echo "work"
      ;;
    Linux)
      echo "home"
      ;;
    *)
      print_error "Unknown OS: $os" >&2
      exit 1
      ;;
  esac
}

# Function to check if PROJECT.yaml exists
project_yaml_exists() {
  [[ -f "PROJECT.yaml" ]]
}

# This script doesn't use project-config.sh library - it defines its own minimal helpers
# No changes needed - this script is standalone

# Minimal task backend detector (PROJECT.yaml override, else env default)
get_task_backend() {
  local env backend
  env=$(detect_environment)
  if project_yaml_exists && command -v yq >/dev/null 2>&1; then
    backend=$(yq -r '.task_management.backend // ""' PROJECT.yaml 2>/dev/null || echo "")
    if [[ -n "$backend" ]] && [[ "$backend" != "null" ]]; then
      echo "$backend"
      return
    fi
  fi
  # Defaults: Work (darwin) = asana, Home (linux) = gitlab
  if [[ "$env" == "work" ]]; then
    echo "asana"
  else
    echo "gitlab"
  fi
}

# Function to get docker registry
get_docker_registry() {
  local env
  env=$(detect_environment)

  if project_yaml_exists; then
    local registry
    registry=$(get_project_value ".docker.registries.${env}" "")
    if [[ -n "$registry" ]]; then
      echo "$registry"
      return
    fi
  fi

  # Fallback to defaults
  case "$env" in
    work)
      echo "ecr"  # AWS ECR
      ;;
    home)
      echo "docker.turnersrus.com"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Function to get CI/CD platform
get_cicd_platform() {
  local env
  env=$(detect_environment)

  if project_yaml_exists; then
    local platform
    platform=$(get_project_value ".ci.platform" "")
    if [[ -n "$platform" ]]; then
      echo "$platform"
      return
    fi
  fi

  # Fallback based on git platform or environment
  local git_platform
  git_platform=$(get_git_platform)

  case "$git_platform" in
    github)
      echo "github-actions"
      ;;
    gitlab)
      echo "gitlab-ci"
      ;;
    *)
      # Fallback to environment defaults
      case "$env" in
        work)
          echo "github-actions"
          ;;
        home)
          echo "gitlab-ci"
          ;;
        *)
          echo "unknown"
          ;;
      esac
      ;;
  esac
}

# Function to get deployment method for environment
get_deployment_method() {
  local env="$1"
  local target="${2:-staging}"  # staging or production

  if project_yaml_exists; then
    local method
    method=$(get_project_value ".deployment.${env}.${target}.method" "")
    if [[ -n "$method" ]]; then
      echo "$method"
      return
    fi
  fi

  # Fallback to defaults
  case "$env" in
    work)
      echo "ssm"  # AWS Systems Manager
      ;;
    home)
      local host
      host=$(get_project_value ".deployment.home.${target}.host" "unknown")
      case "$host" in
        *gcp*)
          echo "gcp"
          ;;
        *)
          echo "ssh"
          ;;
      esac
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Function to display full environment info
show_environment_info() {
  local env
  env=$(detect_environment)

  print_info "Environment Detection"
  echo "─────────────────────────────────────"
  echo "Environment: $env"
  echo "OS: $(uname -s)"
  echo ""

  if project_yaml_exists; then
    print_success "PROJECT.yaml found"
    echo ""
    echo "Git Configuration:"
    echo "  Platform: $(get_git_platform)"
    echo "  Instance: $(get_git_instance)"
    echo "  Repo: $(get_git_repo)"
    echo ""
    echo "Infrastructure:"
    echo "  Docker Registry: $(get_docker_registry)"
    echo "  CI/CD Platform: $(get_cicd_platform)"
    echo "  Secrets Backend: $(get_secrets_backend)"
    echo ""
    echo "Task Management:"
    echo "  Backend: $(get_task_backend)"
    echo ""
    echo "Deployment:"
    echo "  Staging: $(get_deployment_method "$env" "staging")"
    echo "  Production: $(get_deployment_method "$env" "production")"
  else
    print_warning "PROJECT.yaml not found"
    echo ""
    echo "Defaults:"
    echo "  Secrets Backend: $(get_secrets_backend)"
    echo "  CI/CD Platform: $(get_cicd_platform)"
  fi
  echo "─────────────────────────────────────"
}

# Main script logic
main() {
  local command="${1:-env}"

  case "$command" in
    env|environment)
      detect_environment
      ;;
    info|show)
      show_environment_info
      ;;
    git-platform)
      get_git_platform
      ;;
    git-instance)
      get_git_instance
      ;;
    git-repo)
      get_git_repo
      ;;
    task-backend)
      get_task_backend
      ;;
    secrets-backend)
      get_secrets_backend
      ;;
    docker-registry)
      get_docker_registry
      ;;
    cicd-platform)
      get_cicd_platform
      ;;
    deployment-method)
      local env="${2:-$(detect_environment)}"
      local target="${3:-staging}"
      get_deployment_method "$env" "$target"
      ;;
    project-exists)
      if project_yaml_exists; then
        echo "true"
        exit 0
      else
        echo "false"
        exit 1
      fi
      ;;
    help|--help|-h)
      cat <<EOF
Environment Detection Script

Usage: detect-environment.sh [command]

Commands:
  env, environment         Detect environment (work/home)
  info, show              Show full environment information
  git-platform            Get git platform (github/gitlab)
  git-instance            Get git instance URL
  git-repo                Get git repository path
  task-backend            Get task management backend (asana/gitlab)
  secrets-backend         Get secrets backend (aws/infisical)
  docker-registry         Get docker registry
  cicd-platform           Get CI/CD platform (github-actions/gitlab-ci)
  deployment-method [env] [target]
                          Get deployment method for environment and target
  project-exists          Check if PROJECT.yaml exists (exit 0/1)
  help                    Show this help message

Examples:
  detect-environment.sh                    # Returns: work or home
  detect-environment.sh info               # Show all environment info
  detect-environment.sh git-platform       # Returns: github or gitlab
  detect-environment.sh secrets-backend    # Returns: aws or infisical
  detect-environment.sh deployment-method home production

Environment Detection:
  - Darwin (macOS) = work (GitHub, AWS)
  - Linux (WSL) = home (GitLab, Unraid/GCP)

PROJECT.yaml:
  If PROJECT.yaml exists, values are read from it.
  Otherwise, defaults are used based on environment.
EOF
      ;;
    *)
      print_error "Unknown command: $command"
      echo "Run 'detect-environment.sh help' for usage information"
      exit 1
      ;;
  esac
}

main "$@"

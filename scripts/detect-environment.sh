#!/usr/bin/env bash
# Environment Detection Script
#
# Provides the active environment name and environment-specific config to
# any script that asks. Resolution order, most-specific to least-specific:
#
#   1. PROJECT.yaml (per-project override, when present)
#   2. ~/.claude/profiles/active.yaml (machine profile, via load-profile.sh)
#   3. Hard fallback (only used if profile is missing AND no PROJECT.yaml)
#
# Historical note: this file previously hardcoded a personal registry host
# and auto-mapped Darwin→work / Linux→home. Both behaviors leaked personal
# config into shared logic. The script is now profile-driven: it answers
# "what environment am I in?" by reading the profile's active_environment
# field, and "what's the registry?" by reading profile_env_get .registry.host.
#
# Subcommands (preserved for API compatibility with callers):
#   env | environment       Active environment name (e.g. "work", "home")
#   info | show             Pretty-printed dump of all resolved values
#   git-platform            github | gitlab
#   git-instance            github.com | git.example.com | ...
#   git-repo                org/repo (from PROJECT.yaml only)
#   task-backend            asana | gitlab | github | none
#   secrets-backend         aws-secrets-manager | infisical | ...
#   docker-registry         registry host
#   cicd-platform           github-actions | gitlab-ci
#   deployment-method [env] [target=staging]
#                           ssm | ssh | gcp | ...
#   project-exists          Print "true"/"false", exit 0/1

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/lib/load-profile.sh"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_error()   { echo -e "${RED}✗ $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}" >&2; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}" >&2; }

# ----------------------------------------------------------------------
# PROJECT.yaml helpers (local — no dependency on project-config.sh)
# ----------------------------------------------------------------------
project_yaml_exists() { [[ -f "PROJECT.yaml" ]]; }

# get_project_value <yaml-path> [default]
# Reads from PROJECT.yaml. Returns default (or empty) if path is missing,
# PROJECT.yaml is absent, or yq is not installed.
get_project_value() {
  local path="$1"
  local default="${2:-}"
  if ! project_yaml_exists; then echo "$default"; return; fi
  if ! command -v yq >/dev/null 2>&1; then echo "$default"; return; fi
  local val
  val=$(yq -r "$path // \"\"" PROJECT.yaml 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then echo "$default"; else echo "$val"; fi
}

# resolve <project-path> <profile-env-path> [default]
# Two-layer lookup: PROJECT.yaml first, then profile, then default.
resolve() {
  local project_path="$1"
  local profile_path="$2"
  local default="${3:-}"
  local val
  val=$(get_project_value "$project_path" "")
  if [[ -n "$val" ]]; then echo "$val"; return; fi
  val=$(profile_env_get "$profile_path" "")
  if [[ -n "$val" ]]; then echo "$val"; return; fi
  echo "$default"
}

# ----------------------------------------------------------------------
# Public accessors
# ----------------------------------------------------------------------

# detect_environment — name of the active env (work, home, prod, etc.)
detect_environment() {
  local env
  env=$(profile_active_environment 2>/dev/null || true)
  if [[ -n "$env" ]]; then echo "$env"; return; fi

  # Last-resort fallback for first-run / no-profile cases.
  case "$(uname -s)" in
    Darwin) echo "work" ;;
    Linux)  echo "home" ;;
    *)      print_error "Unknown OS and no profile configured"; exit 1 ;;
  esac
}

get_git_platform()    { resolve .git.platform     .git.platform     ""; }
get_git_instance()    { resolve .git.instance     .git.instance     ""; }
get_git_repo()        { get_project_value .git.repo ""; }
get_task_backend()    { resolve .task_management.backend .task_management.backend ""; }
get_secrets_backend() { resolve .secrets.backend  .secrets.backend  ""; }
get_docker_registry() { resolve ".docker.registries.$(detect_environment)" .registry.host ""; }

# CI platform: explicit value first, otherwise derive from git platform.
get_cicd_platform() {
  local val
  val=$(resolve .ci.platform .ci.platform "")
  if [[ -n "$val" ]]; then echo "$val"; return; fi
  case "$(get_git_platform)" in
    github) echo "github-actions" ;;
    gitlab) echo "gitlab-ci" ;;
    *)      echo "" ;;
  esac
}

# Deployment method for a given env+target. PROJECT.yaml is the canonical
# source; profile only carries the list of valid targets, not per-target
# methods (those are project-specific).
get_deployment_method() {
  local env="${1:-$(detect_environment)}"
  local target="${2:-staging}"
  get_project_value ".deployment.${env}.${target}.method" ""
}

# ----------------------------------------------------------------------
# Info / diagnostics
# ----------------------------------------------------------------------
show_environment_info() {
  local env profile
  env=$(detect_environment)
  profile=$(profile_path 2>/dev/null || echo "(none)")

  print_info "Environment Detection"
  echo "─────────────────────────────────────"
  echo "Environment: $env"
  echo "Profile:     $profile"
  echo "OS:          $(uname -s)"
  echo ""
  echo "Git:"
  echo "  Platform: $(get_git_platform)"
  echo "  Instance: $(get_git_instance)"
  echo "  Repo:     $(get_git_repo)"
  echo ""
  echo "Infrastructure:"
  echo "  Docker registry: $(get_docker_registry)"
  echo "  CI/CD platform:  $(get_cicd_platform)"
  echo "  Secrets backend: $(get_secrets_backend)"
  echo ""
  echo "Task management:"
  echo "  Backend: $(get_task_backend)"
  echo ""
  if project_yaml_exists; then
    echo "Deployment:"
    echo "  Staging:    $(get_deployment_method "$env" staging)"
    echo "  Production: $(get_deployment_method "$env" production)"
  else
    print_warning "PROJECT.yaml not found — deployment methods not available"
  fi
  echo "─────────────────────────────────────"
}

# ----------------------------------------------------------------------
# Main dispatch
# ----------------------------------------------------------------------
main() {
  local command="${1:-env}"
  case "$command" in
    env|environment)   detect_environment ;;
    info|show)         show_environment_info ;;
    git-platform)      get_git_platform ;;
    git-instance)      get_git_instance ;;
    git-repo)          get_git_repo ;;
    task-backend)      get_task_backend ;;
    secrets-backend)   get_secrets_backend ;;
    docker-registry)   get_docker_registry ;;
    cicd-platform)     get_cicd_platform ;;
    deployment-method) get_deployment_method "${2:-}" "${3:-staging}" ;;
    project-exists)
      if project_yaml_exists; then echo "true"; exit 0
      else echo "false"; exit 1; fi ;;
    help|--help|-h)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *)
      print_error "Unknown command: $command"
      echo "Run 'detect-environment.sh help' for usage" >&2
      exit 1 ;;
  esac
}

main "$@"

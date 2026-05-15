#!/usr/bin/env bash
set -euo pipefail

# get-default-branch.sh - Determine the default/development branch for git operations
# Supports different branch naming conventions across projects
#
# Usage:
#   source ~/.claude/scripts/get-default-branch.sh
#   DEFAULT_BRANCH=$(get_default_branch [override])
#   DEFAULT_BRANCH=$(get_default_branch "main")        # Force specific branch
#   DEFAULT_BRANCH=$(get_default_branch)               # Auto-detect

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared non-interactive detection
source "${SCRIPT_DIR}/lib/git-utils.sh"

# Override get_default_branch with interactive version that falls back to prompt
get_default_branch() {
  local override="${1:-}"

  # Tier 1: Use override if provided
  if [[ -n "$override" ]]; then
    if git rev-parse --verify "$override" &>/dev/null; then
      echo "$override"
      return 0
    else
      echo "Error: Branch '$override' does not exist" >&2
      return 1
    fi
  fi

  # Tier 2-5: Try non-interactive detection from shared lib
  # (re-implement here since we overrode the function name)
  # PROJECT.yaml
  if [[ -f "PROJECT.yaml" ]] && command -v yq &>/dev/null; then
    local yaml_branch
    yaml_branch=$(yaml_get '.ci.branches.dev // ""' PROJECT.yaml)
    if [[ -n "$yaml_branch" && "$yaml_branch" != "null" ]]; then
      if git rev-parse --verify "$yaml_branch" &>/dev/null; then
        echo "$yaml_branch"
        return 0
      fi
    fi
  fi

  # origin/HEAD
  if git rev-parse refs/remotes/origin/HEAD &>/dev/null 2>&1; then
    local remote_head
    remote_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
    if [[ -n "$remote_head" && "$remote_head" != "null" ]]; then
      echo "$remote_head"
      return 0
    fi
  fi

  # Well-known defaults
  for branch in main master develop dev; do
    if git rev-parse --verify "$branch" &>/dev/null 2>&1; then
      echo "$branch"
      return 0
    fi
  done

  # Tier 6: Interactive prompt (only when stdin is a terminal)
  if [[ -t 0 ]]; then
    echo "Could not determine default branch automatically." >&2
    echo "" >&2
    echo "Available branches:" >&2
    git branch -l | sed 's/^/  /' >&2
    echo "" >&2
    read -p "Enter the default/development branch name: " -r default_branch

    if [[ -z "$default_branch" ]]; then
      echo "Error: No branch specified" >&2
      return 1
    fi

    if git rev-parse --verify "$default_branch" &>/dev/null 2>&1; then
      echo "$default_branch"
      return 0
    else
      echo "Error: Branch '$default_branch' does not exist" >&2
      return 1
    fi
  fi

  # Non-interactive fallback: return "main" like the shared lib
  echo "main"
}

# If script is run directly (not sourced), execute the function
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  get_default_branch "$@"
fi

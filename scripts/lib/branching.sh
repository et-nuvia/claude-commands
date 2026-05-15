#!/usr/bin/env bash
# branching.sh - Task-aware branching utilities
#
# Higher-level branching operations built on top of git-utils.sh.
# Configured via PROJECT.yaml git section.
#
# Provides: get_feature_branch_prefix(), create_feature_branch(), detect_merge_target()
#
# Usage: source "${SCRIPT_DIR}/lib/branching.sh"

# Guard against double-sourcing
[[ -n "${_BRANCHING_LOADED:-}" ]] && return 0
_BRANCHING_LOADED=1

_BRANCHING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies if not already loaded
if ! declare -f yaml_get &>/dev/null; then
    source "${_BRANCHING_DIR}/yaml.sh"
fi
if ! declare -f detect_base_branch &>/dev/null; then
    source "${_BRANCHING_DIR}/git-utils.sh"
fi

# Get the feature branch prefix from PROJECT.yaml (default: "feature/")
# Usage: prefix=$(get_feature_branch_prefix)
get_feature_branch_prefix() {
    local prefix
    prefix=$(yaml_get '.git.branch_prefix // ""' PROJECT.yaml)
    if [[ -z "$prefix" ]]; then
        prefix="feature/"
    fi
    echo "$prefix"
}

# Create a feature branch following the project's naming convention
# Returns the branch name (does NOT switch to it)
#
# Usage: branch=$(create_feature_branch "A3F2B9" "add-user-auth")
#        branch=$(create_feature_branch "42" "fix-login-bug" "dev")
#
# Parameters:
#   $1 - task_id: Task identifier
#   $2 - description: Kebab-case description
#   $3 - base_branch: (optional) Branch to create from (auto-detected if omitted)
create_feature_branch() {
    local task_id="$1"
    local description="$2"
    local base_branch="${3:-}"

    local prefix
    prefix=$(get_feature_branch_prefix)

    # Build branch name: prefix + task_id + description
    local branch_name="${prefix}${task_id}/${description}"

    # Determine base branch
    if [[ -z "$base_branch" ]]; then
        base_branch=$(detect_merge_target)
    fi

    # Check if branch already exists
    if git rev-parse --verify "$branch_name" &>/dev/null; then
        echo "$branch_name"
        return 0
    fi

    # Create and checkout branch
    git checkout -b "$branch_name" "$base_branch" 2>/dev/null || {
        echo ""
        return 1
    }

    echo "$branch_name"
}

# Detect the appropriate merge target for the current branch
# Wraps detect_base_branch() with PROJECT.yaml overrides
#
# Usage: target=$(detect_merge_target)
#        target=$(detect_merge_target "feature/A3F/add-auth")
detect_merge_target() {
    local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"

    # If on a protected branch, merge target is the next environment up
    if declare -f is_protected_branch &>/dev/null && is_protected_branch "$branch"; then
        local staging
        staging=$(yaml_get '.ci.branches.staging // ""' PROJECT.yaml)
        local production
        production=$(yaml_get '.ci.branches.production // ""' PROJECT.yaml)

        if [[ "$branch" == "$staging" && -n "$production" ]]; then
            echo "$production"
            return 0
        fi
    fi

    # For feature branches, use detect_base_branch
    detect_base_branch
}

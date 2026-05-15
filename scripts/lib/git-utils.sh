#!/usr/bin/env bash
# git-utils.sh - Shared git branch detection utilities
#
# Source this file to get branch detection functions.
# Usage: source "${SCRIPT_DIR}/lib/git-utils.sh"
#
# Functions:
#   detect_base_branch  - Find which branch current branch was forked from
#   get_default_branch  - Find the repo's default/development branch (non-interactive)

_GIT_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source yaml helper if not already loaded
if ! declare -f yaml_get &>/dev/null; then
    source "${_GIT_UTILS_DIR}/yaml.sh"
fi

# Check if a branch is protected (configured in PROJECT.yaml ci.branches.*)
# Returns 0 if protected, 1 if not protected or no config found.
# Usage: if is_protected_branch "dev"; then echo "protected!"; fi
is_protected_branch() {
    local branch="$1"
    [[ -z "$branch" ]] && return 1
    [[ ! -f "PROJECT.yaml" ]] && return 1

    # Iterate all values under ci.branches (dev, staging, production, and any custom keys)
    local val
    while IFS= read -r val; do
        [[ -n "$val" ]] && [[ "$val" == "$branch" ]] && return 0
    done < <(yaml_get '.ci.branches[]' PROJECT.yaml 2>/dev/null)

    return 1
}

# Detect the base branch that the current branch was forked from.
#
# Strategy: find the local branch whose merge-base is closest to HEAD
# (fewest commits between merge-base and HEAD = the fork parent).
#
# Fallbacks: get_default_branch
#
# Usage: BASE=$(detect_base_branch)
detect_base_branch() {
    local current head_sha best_branch best_distance
    current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    best_branch=""
    best_distance=999999

    if [[ -n "$current" ]] && [[ -n "$head_sha" ]]; then
        local candidate mb distance
        for candidate in $(git branch --format='%(refname:short)' 2>/dev/null); do
            [[ "$candidate" == "$current" ]] && continue
            mb=$(git merge-base "$candidate" "$head_sha" 2>/dev/null || echo "")
            [[ -z "$mb" ]] && continue
            distance=$(git rev-list --count "${mb}..${head_sha}" 2>/dev/null || echo "999999")
            if [[ "$distance" -lt "$best_distance" ]] && [[ "$distance" -gt 0 ]]; then
                best_distance="$distance"
                best_branch="$candidate"
            fi
        done
    fi

    if [[ -n "$best_branch" ]]; then
        echo "$best_branch"
        return
    fi

    # Fallback to default branch detection
    get_default_branch
}

# Detect the repo's default/development branch (non-interactive).
#
# Resolution order:
#   1. Override argument (if provided and branch exists)
#   2. PROJECT.yaml ci.branches.dev (if file exists and yq available)
#   3. origin/HEAD symbolic ref
#   4. Well-known branch names: main, master, develop, dev
#   5. Fallback: "main"
#
# Usage: DEFAULT=$(get_default_branch)
#        DEFAULT=$(get_default_branch "dev")  # force specific branch
get_default_branch() {
    local override="${1:-}"

    # Tier 1: Use override if provided and valid
    if [[ -n "$override" ]]; then
        if git rev-parse --verify "$override" &>/dev/null; then
            echo "$override"
            return 0
        fi
    fi

    # Tier 2: PROJECT.yaml ci.branches.dev
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

    # Tier 3: origin/HEAD
    local remote_head
    remote_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
    if [[ -n "$remote_head" && "$remote_head" != "null" ]]; then
        echo "$remote_head"
        return 0
    fi

    # Tier 4: Well-known defaults
    for branch in main master develop dev; do
        if git rev-parse --verify "$branch" &>/dev/null; then
            echo "$branch"
            return 0
        fi
    done

    # Tier 5: Last resort
    echo "main"
}

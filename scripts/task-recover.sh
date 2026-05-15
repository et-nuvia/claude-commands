#!/usr/bin/env bash
set -euo pipefail

# task-recover.sh - Rebuild .current-task from branch context
#
# Usage:
#   task-recover.sh --json          # Structured output
#   task-recover.sh                 # Human-readable output
#
# Derives task state from the current branch name and TSK document.
# Must be run on a feature/bugfix branch (not default/staging/production).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

OUTPUT_MODE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        *) shift ;;
    esac
done

output_error() {
    local msg="$1"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{"status": "error", "next_action": "fix_error", "message": "$msg"}
EOF
    else
        echo "Error: $msg" >&2
    fi
    exit 1
}

output_success() {
    local task_id="$1"
    local branch="$2"
    local task_doc="$3"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{"status": "success", "next_action": "display_summary", "message": "Recovered .current-task for $task_id", "task_id": "$task_id", "branch": "$branch", "task_doc": "$task_doc"}
EOF
    else
        echo "Recovered .current-task for task $task_id on branch $branch"
    fi
}

# 1. Get current branch
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ -z "$branch" ]]; then
    output_error "Not in a git repository"
fi

# 2. Check it's not a default/staging/production branch
default_branch=$(get_default_branch 2>/dev/null || echo "main")

# Also check PROJECT.yaml for staging/production branch names
staging_branch=$(yaml_get '.ci.branches.staging // ""' PROJECT.yaml)
prod_branch=$(yaml_get '.ci.branches.production // ""' PROJECT.yaml)
# yaml_get normalizes null to empty, no guard needed

if [[ "$branch" == "$default_branch" ]] || \
   [[ "$branch" == "main" ]] || [[ "$branch" == "master" ]] || \
   [[ "$branch" == "dev" ]] || [[ "$branch" == "develop" ]] || \
   [[ -n "$staging_branch" && "$branch" == "$staging_branch" ]] || \
   [[ -n "$prod_branch" && "$branch" == "$prod_branch" ]]; then
    output_error "Cannot recover from branch '$branch' — must be on a feature/bugfix branch"
fi

# 3. Extract task ID from branch name (feature/XXXXXX-desc, bugfix/XXXXXX-desc, etc.)
task_id=$(echo "$branch" | sed -n 's|^[^/]*/\([A-Fa-f0-9]\{6\}\)-.*|\1|p')
if [[ -z "$task_id" ]]; then
    output_error "Cannot extract task ID from branch '$branch' — expected pattern: type/XXXXXX-description"
fi
task_id=$(echo "$task_id" | tr 'a-f' 'A-F')

# 4. Find TSK document
task_doc=$(find_primary "$task_id")
if [[ -z "$task_doc" ]]; then
    output_error "No TSK/INC document found for task $task_id — create one with /task-capture"
fi

# 5. Parse External Tracking section for tracker info
tracker_backend=""
tracker_id=""

backend_from_yaml=$(yaml_get '.task_management.backend // ""' PROJECT.yaml)
# yaml_get normalizes null to empty

if [[ -n "$backend_from_yaml" ]]; then
    tracker_backend="$backend_from_yaml"

    # Extract tracker ID from TSK doc based on backend type
    case "$tracker_backend" in
        asana)
            tracker_id=$(grep -A 20 "^## External Tracking" "$task_doc" 2>/dev/null | \
                         grep "Task GID:" | grep -oE '[0-9]{10,}' | head -1 || echo "")
            ;;
        gitlab)
            tracker_id=$(grep -A 20 "^## External Tracking" "$task_doc" 2>/dev/null | \
                         grep "^- Issue:" | sed 's/.*#\([0-9]*\).*/\1/' | head -1 || echo "")
            ;;
        github)
            tracker_id=$(grep -A 20 "^## External Tracking" "$task_doc" 2>/dev/null | \
                         grep "^- Issue:" | sed 's/.*#\([0-9]*\).*/\1/' | head -1 || echo "")
            ;;
    esac

    # If no tracker ID found, don't set a backend either
    if [[ -z "$tracker_id" ]]; then
        tracker_backend=""
    fi
fi

# 6. Determine parent branch (default branch as best guess for recovery)
parent_branch="$default_branch"

# 7. Write .current-task
write_current_task "$task_id" "$branch" "$parent_branch" "$task_doc" "$tracker_backend" "$tracker_id"

output_success "$task_id" "$branch" "$task_doc"

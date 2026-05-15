#!/usr/bin/env bash
# validate-git-state.sh - Validate git state before deployment
# Usage: ./scripts/validate-git-state.sh [--dev-branch <branch>] [--staging-branch <branch>]
# Returns: 0 on success, 1 on failure
# Output: JSON status to stdout

set -euo pipefail

# Detect branch if not provided
detect_dev_branch() {
  for branch in dev develop development; do
    if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
      echo "$branch"
      return 0
    fi
  done
  echo "dev"
}

detect_staging_branch() {
  for branch in staging stage stg main master; do
    if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
      echo "$branch"
      return 0
    fi
  done
  echo "staging"
}

DEV_BRANCH=""
STAGING_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev-branch)     DEV_BRANCH="$2";     shift 2 ;;
    --staging-branch) STAGING_BRANCH="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dev-branch <branch>] [--staging-branch <branch>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Auto-detect branches if not provided
if [[ -z "$DEV_BRANCH" ]]; then
  DEV_BRANCH=$(detect_dev_branch)
  echo "⚠️  Dev branch not specified, using: $DEV_BRANCH" >&2
fi

if [[ -z "$STAGING_BRANCH" ]]; then
  STAGING_BRANCH=$(detect_staging_branch)
  echo "⚠️  Staging branch not specified, using: $STAGING_BRANCH" >&2
fi

validate_git() {
  local checks_passed=true
  local errors=()

  # Check for uncommitted changes
  if [[ -n "$(git status --porcelain)" ]]; then
    errors+=("Uncommitted changes detected")
    checks_passed=false
  fi

  # Fetch latest branches
  git fetch origin "$DEV_BRANCH" "$STAGING_BRANCH" >/dev/null 2>&1 || true

  # Check for unpushed commits on dev
  UNPUSHED=$(git log "origin/$DEV_BRANCH".."$DEV_BRANCH" 2>/dev/null | wc -l)
  if [[ $UNPUSHED -gt 0 ]]; then
    errors+=("Unpushed commits on $DEV_BRANCH: $UNPUSHED")
    checks_passed=false
  fi

  # Check if branches exist
  if ! git rev-parse --verify "origin/$STAGING_BRANCH" >/dev/null 2>&1; then
    errors+=("Staging branch does not exist: $STAGING_BRANCH")
    checks_passed=false
  fi

  if ! git rev-parse --verify "origin/$DEV_BRANCH" >/dev/null 2>&1; then
    errors+=("Dev branch does not exist: $DEV_BRANCH")
    checks_passed=false
  fi

  # Check for merge conflicts
  if [[ $checks_passed == true ]]; then
    MERGE_BASE=$(git merge-base "origin/$DEV_BRANCH" "origin/$STAGING_BRANCH" 2>/dev/null || echo "")
    if [[ -n "$MERGE_BASE" ]]; then
      if git merge-tree "$MERGE_BASE" "origin/$STAGING_BRANCH" "origin/$DEV_BRANCH" 2>/dev/null | grep -q "<<<<<"; then
        errors+=("Merge conflicts detected between $DEV_BRANCH and $STAGING_BRANCH")
        checks_passed=false
      fi
    fi
  fi

  # Get commit count (two-dot: commits on DEV not on STAGING — the forward-merge set)
  # Three-dot would be symmetric difference and include STAGING-only commits too.
  COMMIT_COUNT=$(git log "origin/$STAGING_BRANCH".."origin/$DEV_BRANCH" --oneline 2>/dev/null | wc -l | tr -d ' ')
  # Three-dot diff is intentional: files changed on DEV since its merge-base with STAGING
  CHANGED_FILES=$(git diff "origin/$STAGING_BRANCH"..."origin/$DEV_BRANCH" --name-only 2>/dev/null | wc -l | tr -d ' ')

  # Build errors JSON (bash 3.2 quirk: "${arr[@]}" on empty array with set -u expands to 1 empty string)
  local errors_json="[]"
  if [[ ${#errors[@]} -gt 0 ]]; then
    local joined=""
    local i
    for i in "${!errors[@]}"; do
      [[ -n "$joined" ]] && joined+=","
      # Escape backslashes and double quotes for JSON
      local esc="${errors[$i]//\\/\\\\}"
      esc="${esc//\"/\\\"}"
      joined+="\"$esc\""
    done
    errors_json="[$joined]"
  fi

  # Output JSON result
  cat <<EOF
{
  "valid": $([[ "$checks_passed" == true ]] && echo "true" || echo "false"),
  "commits": $COMMIT_COUNT,
  "files_changed": $CHANGED_FILES,
  "errors": $errors_json
}
EOF

  [[ "$checks_passed" == true ]] && return 0 || return 1
}

validate_git

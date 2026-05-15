#!/usr/bin/env bash
# task-merge.sh - Deterministic feature-to-dev merge orchestrator
# Usage: ./task-merge.sh --stage <stage> [--message <msg>] [--branch <name>]
# Stages: info, merge, cleanup

set -euo pipefail

# Colors for stderr output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Configuration
PROJECT_FILE="PROJECT.yaml"
STAGE="info"
CUSTOM_MSG=""
TARGET_BRANCH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      STAGE="$2"
      shift 2
      ;;
    --message)
      CUSTOM_MSG="$2"
      shift 2
      ;;
    --branch)
      TARGET_BRANCH="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}" >&2
      exit 2
      ;;
  esac
done

# Ensure PROJECT.yaml exists
if [[ ! -f "$PROJECT_FILE" ]]; then
  echo -e "${RED}ERROR: $PROJECT_FILE not found${NC}" >&2
  echo '{"success": false, "error": "PROJECT.yaml not found"}'
  exit 2
fi

# Load dev branch from PROJECT.yaml
DEV_BRANCH=$(yaml_get '.ci.branches.dev // "dev"' "$PROJECT_FILE")

# Helper: JSON output
output_json() {
  echo "$1"
}

# ============================================================================
# Stage: Info (Collection of all details the agent needs)
# ============================================================================
info_stage() {
  echo -e "${BLUE}Stage: Collecting merge information...${NC}" >&2
  
  local task_info
  task_info=$( "${SCRIPT_DIR}/check-current-task.sh" 2>/dev/null || true )
  local current_branch=$(echo "$task_info" | jq -r '.current_branch // empty')
  if [[ -z "$current_branch" ]]; then
    current_branch=$(git rev-parse --abbrev-ref HEAD)
  fi
  
  # Fetch latest (if remote exists)
  if git remote | grep -q .; then
    git fetch origin "$DEV_BRANCH" "$current_branch" --tags --prune >/dev/null 2>&1 || true
  fi
  
  # Commit counts
  local dev_ref="origin/$DEV_BRANCH"
  if ! git rev-parse --verify "$dev_ref" >/dev/null 2>&1; then
    dev_ref="$DEV_BRANCH"
  fi
  
  local ahead=$(git rev-list --count "$dev_ref..HEAD" 2>/dev/null || echo "0")
  local behind=$(git rev-list --count "HEAD..$dev_ref" 2>/dev/null || echo "0")
  
  # Stats
  local stats=$(git diff --stat "$dev_ref..HEAD" | tail -1 || echo "No changes")
  
  # Modified files (ignoring untracked)
  local modified_files=$(git status --porcelain -uno)
  local modified_list="[]"
  if [[ -n "$modified_files" ]]; then
    modified_list=$(echo "$modified_files" | awk '{print $2}' | jq -R . | jq -s .)
  fi
  
  # Commit summary for curation
  local commit_summary=$(git log "$dev_ref..HEAD" --pretty=format:"- %s (%h)" || echo "")
  
  local result=$(jq -n \
    --arg current "$current_branch" \
    --arg dev "$DEV_BRANCH" \
    --argjson ahead "$ahead" \
    --argjson behind "$behind" \
    --arg stats "$stats" \
    --argjson modified "$modified_list" \
    --arg summary "$commit_summary" \
    '{
      "current_branch": $current,
      "dev_branch": $dev,
      "commits_ahead": $ahead,
      "commits_behind": $behind,
      "stats": $stats,
      "modified_files": $modified,
      "commit_summary": $summary
    }')
    
  output_json "$result"
}

# ============================================================================
# Stage: Merge (Squash merge feature to dev)
# ============================================================================
merge_stage() {
  if [[ -z "$CUSTOM_MSG" ]]; then
    echo -e "${RED}ERROR: --message is required for merge stage${NC}" >&2
    exit 2
  fi

  local current_branch=$(git rev-parse --abbrev-ref HEAD)
  echo -e "${BLUE}Stage: Performing squash merge of $current_branch to $DEV_BRANCH...${NC}" >&2
  
  # 1. Fetch and Pull latest dev (if remote exists)
  git checkout "$DEV_BRANCH" >/dev/null 2>&1
  if git remote | grep -q .; then
    git pull origin "$DEV_BRANCH" >/dev/null 2>&1 || true
  fi
  
  # 2. Perform squash merge using git-merge.sh
  local merge_result=$(~/.claude/scripts/git-merge.sh --json --merge --source "$current_branch" --target "$DEV_BRANCH" --squash --message "$CUSTOM_MSG")
  local merge_exit=$?
  
  output_json "$merge_result"
  return $merge_exit
}

# ============================================================================
# Stage: Cleanup (Force delete branches)
# ============================================================================
cleanup_stage() {
  if [[ -z "$TARGET_BRANCH" ]]; then
    echo -e "${RED}ERROR: --branch is required for cleanup stage${NC}" >&2
    exit 2
  fi

  # Safety: never delete dev branch
  if [[ "$TARGET_BRANCH" == "$DEV_BRANCH" ]]; then
    echo -e "${RED}ERROR: Cannot delete the development branch ($DEV_BRANCH)${NC}" >&2
    exit 1
  fi

  echo -e "${BLUE}Stage: Force-deleting branch $TARGET_BRANCH...${NC}" >&2
  
  # Use force delete (-D) because squash merges aren't considered "merged" by git
  git branch -D "$TARGET_BRANCH" >/dev/null 2>&1 || true
  
  # Delete remote (if exists)
  if git remote | grep -q .; then
    git push origin --delete "$TARGET_BRANCH" >/dev/null 2>&1 || true
  fi
  
  output_json "{\"success\": true, \"cleaned_up\": \"$TARGET_BRANCH\"}"
}

# ============================================================================
# Main Execution
# ============================================================================

case "$STAGE" in
  info)
    info_stage
    ;;
  merge)
    merge_stage
    ;;
  cleanup)
    cleanup_stage
    ;;
  *)
    echo -e "${RED}Invalid stage: $STAGE${NC}" >&2
    exit 2
    ;;
esac

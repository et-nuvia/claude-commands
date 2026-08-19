#!/usr/bin/env bash
set -euo pipefail

# git-rebase.sh - Rebase a branch onto another branch with intelligent validation
#
# Standard pattern script for /git-rebase command
# Provides JSON and raw output modes with section-based execution
#
# Usage:
#   git-rebase.sh --json --full [--branch <branch>] [--onto <branch>]
#   git-rebase.sh --json --analyze [--branch <branch>] [--onto <branch>]
#   git-rebase.sh --json --execute [--branch <branch>] [--onto <branch>]
#   git-rebase.sh --raw --<section> [--branch <branch>] [--onto <branch>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Output Framework Setup
# ============================================================================

OUTPUT_MODE="json"
SECTION=""

map_status_to_action() {
    case "$1" in
        success)                echo "display_summary" ;;
        ready_for_confirmation) echo "confirm_action" ;;
        not_needed)             echo "display_summary" ;;
        needs_decision)         echo "ask_uncommitted_strategy" ;;
        conflict)               echo "resolve_conflicts" ;;
        *)                      echo "fix_error" ;;
    esac
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/git-utils.sh"

# ============================================================================
# Configuration
# ============================================================================

BRANCH_TO_REBASE=""
REBASE_ONTO=""
CURRENT_BRANCH=""
MERGE_BASE=""

# ============================================================================
# Section Functions
# ============================================================================

section_parse_args() {
  log "Parsing arguments"

  CURRENT_BRANCH=$(git branch --show-current)

  # Use provided values or fall back to current branch
  BRANCH_TO_REBASE="${BRANCH_TO_REBASE:-$CURRENT_BRANCH}"

  # Auto-detect onto branch if not provided
  if [[ -z "$REBASE_ONTO" ]]; then
    REBASE_ONTO=$(get_default_branch)
  fi

  log "Branch to rebase: $BRANCH_TO_REBASE"
  log "Rebase onto: $REBASE_ONTO"
}

section_validate() {
  SECTION="validate"
  log "${BLUE}=== Validating rebase conditions ===${NC}"

  local branch="$1"
  local onto="$2"
  local errors=()

  # Check for uncommitted changes (ignore untracked files) — ask user, don't hard error
  local has_unstaged has_staged
  has_unstaged=$(git diff --name-only 2>/dev/null)
  has_staged=$(git diff --cached --name-only 2>/dev/null)
  if [[ -n "$has_unstaged" || -n "$has_staged" ]]; then
    local changed_files
    changed_files=$(printf '%s\n' "$has_unstaged" "$has_staged" | grep -v '^$' | sort -u)
    local file_count
    file_count=$(echo "$changed_files" | wc -l | tr -d ' ')
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      exit_with_json "needs_decision" \
        "Working directory has $file_count uncommitted file(s)" \
        "$changed_files" \
        "\"changed_file_count\": $file_count, \"branch\": \"$branch\", \"onto\": \"$onto\", \"options\": [\"commit_first\", \"stash\", \"cancel\"]"
    else
      echo "⚠ Working directory has uncommitted changes:"
      echo "$changed_files" | sed 's/^/  /'
      echo ""
      echo "Options: commit first, stash, or cancel"
      return 1
    fi
  fi

  # Check if branch exists
  if ! git rev-parse --verify "$branch" &>/dev/null; then
    errors+=("Branch '$branch' does not exist")
  fi

  # Check if onto branch exists
  if ! git rev-parse --verify "$onto" &>/dev/null; then
    errors+=("Target branch '$onto' does not exist")
  fi

  # Check for protected branches
  if is_protected_branch "$branch"; then
    errors+=("Cannot rebase protected branch '$branch' onto another branch")
  fi

  # Fetch latest from remote
  log "Fetching latest from remote"
  git fetch origin &>/dev/null || true

  if [[ ${#errors[@]} -gt 0 ]]; then
    local error_details
    error_details=$(printf '%s\n' "${errors[@]}")
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      exit_with_json "error" "Validation failed" "$error_details"
    else
      echo "❌ Validation failed:"
      printf '  - %s\n' "${errors[@]}"
      return 1
    fi
  fi

  log "✓ Validation successful"
}

section_analyze() {
  SECTION="analyze"
  log "${BLUE}=== Analyzing rebase requirements ===${NC}"

  local branch="$1"
  local onto="$2"

  # Get merge base (common ancestor)
  MERGE_BASE=$(git merge-base "$branch" "$onto")
  log "Merge base: $MERGE_BASE"

  # Get commit counts
  local branch_commits_ahead
  local onto_commits_ahead
  branch_commits_ahead=$(git rev-list --count "$onto".."$branch")
  onto_commits_ahead=$(git rev-list --count "$branch".."$onto")

  log "Branch commits ahead: $branch_commits_ahead"
  log "Target commits ahead: $onto_commits_ahead"

  # Check if rebase is needed
  local rebase_needed="yes"
  local reason=""
  local status="ready_for_confirmation"

  if [[ "$onto_commits_ahead" -eq 0 ]]; then
    rebase_needed="no"
    reason="Target branch '$onto' has no new commits since branch diverged"
    status="not_needed"
  fi

  # Get commits that will be replayed
  local commits_json
  if [[ "$branch_commits_ahead" -gt 0 ]]; then
    commits_json=$(git log --oneline "$onto".."$branch" | jq -R . | jq -s .)
  else
    commits_json="[]"
  fi

  # Get files modified in both branches (potential conflicts)
  local onto_files branch_files conflict_files
  onto_files=$(git diff --name-only "$MERGE_BASE".."$onto" | sort)
  branch_files=$(git diff --name-only "$MERGE_BASE".."$branch" | sort)
  conflict_files=$(comm -12 <(echo "$onto_files") <(echo "$branch_files") | jq -R . | jq -s .)

  # Check remote status
  local remote_exists="no"
  local requires_force_push="no"
  if git rev-parse --verify "origin/$branch" &>/dev/null; then
    remote_exists="yes"
    requires_force_push="yes"
  fi

  # Get diff stats
  local diff_stat
  diff_stat=$(git diff --stat "$onto".."$branch")

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    local next_action
    next_action=$(map_status_to_action "$status")

    local message
    if [[ "$rebase_needed" == "yes" ]]; then
      message="Rebase analysis complete"
    else
      message="Rebase not needed"
    fi

    log_json "$(jq -n \
      --arg status "$status" \
      --arg next_action "$next_action" \
      --arg section "analyze" \
      --arg message "$message" \
      --arg branch "$branch" \
      --arg onto "$onto" \
      --arg merge_base "$MERGE_BASE" \
      --argjson branch_commits_ahead "$branch_commits_ahead" \
      --argjson onto_commits_ahead "$onto_commits_ahead" \
      --arg rebase_needed "$rebase_needed" \
      --arg reason "$reason" \
      --argjson commits "$commits_json" \
      --argjson potential_conflict_files "$conflict_files" \
      --arg remote_exists "$remote_exists" \
      --arg requires_force_push "$requires_force_push" \
      --arg diff_stat "$diff_stat" \
      '{
        status: $status,
        next_action: $next_action,
        section: $section,
        message: $message,
        timestamp: now|todate,
        analysis: {
          branch: $branch,
          onto: $onto,
          merge_base: $merge_base,
          branch_commits_ahead: $branch_commits_ahead,
          onto_commits_ahead: $onto_commits_ahead,
          rebase_needed: $rebase_needed,
          reason: $reason,
          commits: $commits,
          potential_conflict_files: $potential_conflict_files,
          remote_exists: $remote_exists,
          requires_force_push: $requires_force_push,
          diff_stat: $diff_stat
        }
      }')"
  else
    echo "=== Rebase Analysis ==="
    echo "Branch to rebase: $branch"
    echo "Rebase onto: $onto"
    echo "Merge base: $MERGE_BASE"
    echo "Branch commits ahead: $branch_commits_ahead"
    echo "Target commits ahead: $onto_commits_ahead"
    echo "Rebase needed: $rebase_needed"
    echo "Reason: $reason"
    echo ""
    echo "Commits to replay:"
    git log --oneline "$onto".."$branch"
    echo ""
    echo "Potential conflict files:"
    echo "$conflict_files" | jq -r '.[]'
    echo ""
    echo "Remote status:"
    echo "  Exists on remote: $remote_exists"
    echo "  Requires force push: $requires_force_push"
    echo ""
    echo "Diff stats:"
    echo "$diff_stat"
  fi

  # Return non-zero if rebase not needed
  [[ "$rebase_needed" == "yes" ]]
}

section_execute() {
  SECTION="execute"
  log "${BLUE}=== Executing rebase ===${NC}"

  local branch="$1"
  local onto="$2"

  # Checkout the branch
  log "Checking out branch: $branch"
  git checkout "$branch" &>/dev/null

  # Perform the rebase
  log "Rebasing $branch onto $onto"
  if ! git rebase "$onto" 2>&1; then
    # Check for conflicts
    local conflict_files
    conflict_files=$(git diff --name-only --diff-filter=U | jq -R . | jq -s .)

    if [[ "$OUTPUT_MODE" == "json" ]]; then
      local next_action
      next_action=$(map_status_to_action "conflict")

      log_json "$(jq -n \
        --arg status "conflict" \
        --arg next_action "$next_action" \
        --arg section "execute" \
        --arg message "Merge conflicts detected during rebase" \
        --arg branch "$branch" \
        --arg onto "$onto" \
        --argjson conflict_files "$conflict_files" \
        --argjson next_steps '["Resolve conflicts in listed files", "Stage resolved files: git add <files>", "Continue rebase: git rebase --continue", "Or abort: git rebase --abort"]' \
        '{
          status: $status,
          next_action: $next_action,
          section: $section,
          message: $message,
          timestamp: now|todate,
          branch: $branch,
          onto: $onto,
          conflict_files: $conflict_files,
          next_steps: $next_steps
        }')"
    else
      echo "❌ Merge conflicts detected"
      echo "Conflicted files:"
      git diff --name-only --diff-filter=U
      echo ""
      echo "Next steps:"
      echo "  1. Resolve conflicts in listed files"
      echo "  2. Stage resolved files: git add <files>"
      echo "  3. Continue rebase: git rebase --continue"
      echo "  4. Or abort: git rebase --abort"
    fi
    return 1
  fi

  # Rebase successful
  local new_base
  new_base=$(git rev-parse HEAD)

  # Check if we need to regenerate docs
  local docs_updated="no"
  if [[ -f "docs/SEQUENCE-TRACKER.md" ]] || [[ -f "docs/DOCUMENT-INDEX.md" ]]; then
    log "Regenerating documentation"
    if "${SCRIPT_DIR}/update-docs.sh" --docs-dir docs &>/dev/null; then
      if ! git diff --quiet docs/SEQUENCE-TRACKER.md docs/DOCUMENT-INDEX.md 2>/dev/null; then
        git add docs/SEQUENCE-TRACKER.md docs/DOCUMENT-INDEX.md 2>/dev/null || true
        docs_updated="yes"
      fi
    fi
  fi

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    exit_with_json "success" "Rebase completed successfully" "" \
      "\"branch\": \"$branch\", \"onto\": \"$onto\", \"new_base\": \"$new_base\", \"docs_updated\": \"$docs_updated\""
  else
    echo "✓ Rebase completed successfully"
    echo "Branch: $branch"
    echo "New base: $new_base"
    [[ "$docs_updated" == "yes" ]] && echo "Documentation updated and staged"
  fi
}

section_push() {
  SECTION="push"
  log "${BLUE}=== Pushing to remote ===${NC}"

  local branch="$1"

  # Check if remote branch exists
  if ! git rev-parse --verify "origin/$branch" &>/dev/null; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      exit_with_json "success" "Remote branch does not exist, no push needed"
    else
      echo "ℹ️  Remote branch does not exist, no push needed"
    fi
    return 0
  fi

  # Push with --force-with-lease
  log "Pushing with --force-with-lease"
  if git push --force-with-lease origin "$branch" 2>&1; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      exit_with_json "success" "Successfully pushed to remote with force-with-lease" "" \
        "\"branch\": \"$branch\""
    else
      echo "✓ Successfully pushed to remote"
    fi
  else
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      exit_with_json "error" "Force push failed - remote has been updated by someone else" \
        "Use 'git push --force origin $branch' only if you're certain you want to overwrite remote changes"
    else
      echo "❌ Force push failed"
      echo "Remote has been updated by someone else"
      echo "Use 'git push --force origin $branch' only if you're certain"
    fi
    return 1
  fi
}

# ============================================================================
# Main Workflow
# ============================================================================

run_full_workflow() {
  section_parse_args

  # Validate
  if ! section_validate "$BRANCH_TO_REBASE" "$REBASE_ONTO"; then
    return 1
  fi

  # Analyze — outputs JSON with status and returns
  # Command will show the plan and wait for user confirmation
  section_analyze "$BRANCH_TO_REBASE" "$REBASE_ONTO"
}

run_execute_workflow() {
  section_parse_args

  # Execute rebase
  if ! section_execute "$BRANCH_TO_REBASE" "$REBASE_ONTO"; then
    return 1
  fi

  # Push to remote if needed
  section_push "$BRANCH_TO_REBASE"
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  local section="full"

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        OUTPUT_MODE="json"
        shift
        ;;
      --raw)
        OUTPUT_MODE="raw"
        shift
        ;;
      --full)
        section="full"
        shift
        ;;
      --analyze)
        section="analyze"
        shift
        ;;
      --execute)
        section="execute"
        shift
        ;;
      --push)
        section="push"
        shift
        ;;
      --validate)
        section="validate"
        shift
        ;;
      --branch)
        BRANCH_TO_REBASE="$2"
        shift 2
        ;;
      --onto)
        REBASE_ONTO="$2"
        shift 2
        ;;
      -h|--help)
        echo "Usage: $0 [--json|--raw] [--full|--analyze|--execute|--push|--validate] [--branch <branch>] [--onto <branch>]" >&2
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
    esac
  done

  # Route to appropriate section or workflow
  case "$section" in
    full)
      run_full_workflow
      ;;
    analyze)
      section_parse_args
      section_validate "$BRANCH_TO_REBASE" "$REBASE_ONTO" && section_analyze "$BRANCH_TO_REBASE" "$REBASE_ONTO"
      ;;
    execute)
      run_execute_workflow
      ;;
    validate)
      section_parse_args
      section_validate "$BRANCH_TO_REBASE" "$REBASE_ONTO"
      ;;
    push)
      section_parse_args
      section_push "$BRANCH_TO_REBASE"
      ;;
    *)
      SECTION="unknown"
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        exit_with_json "error" "Unknown section: $section" "Valid sections: full, analyze, execute, validate, push"
      else
        echo "❌ Unknown section: $section"
        echo "Valid sections: full, analyze, execute, validate, push"
      fi
      return 1
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# create-pr.sh - Create PR/MR with git operations, output JSON for LLM description
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/create-pr.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --analyze: Analyze commits and changes only
#   --push:    Push branch to remote only
#   --create:  Create PR/MR only (requires title and description)
#   --full:    Analyze + push + output JSON for LLM to generate description
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. Script returns JSON with commit data
#   3. LLM generates PR description from commit data
#   4. LLM calls gh/gitlab CLI to create PR with description
#
# Features:
#   - Platform detection (GitHub/GitLab)
#   - Commit analysis for LLM description generation
#   - Auto-push to remote
#   - --raw mode for debugging

# Script directory (needed for sourcing library)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/git-utils.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"
PLATFORM=""
CURRENT_BRANCH=""
BASE_BRANCH=""
PR_TITLE=""
ISSUE_NUMBER=""
COMMIT_COUNT=0
FILES_CHANGED=0
LINES_ADDED=0
LINES_REMOVED=0

# Data for LLM
COMMITS_JSON=""
FILES_JSON=""
DIFF_STAT=""

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Analyze commits and changes
section_analyze() {
    log "${BLUE}Analyzing Commits and Changes${NC}"

    # Detect platform
    if [[ -f "PROJECT.yaml" ]]; then
        PLATFORM=$(yaml_get '.git.platform' PROJECT.yaml)
    fi

    if [[ -z "$PLATFORM" ]] || [[ "$PLATFORM" == "null" ]]; then
        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")

        if [[ "$remote_url" =~ github\.com ]]; then
            PLATFORM="github"
        elif [[ "$remote_url" =~ gitlab ]]; then
            PLATFORM="gitlab"
        else
            exit_with_json "error" "Could not detect platform" "Remote: $remote_url"
        fi
    fi

    # Get branches
    CURRENT_BRANCH=$(git branch --show-current)
    if [[ -z "$CURRENT_BRANCH" ]]; then
        exit_with_json "error" "Not on a branch" "Detached HEAD state"
    fi

    if [[ -z "$BASE_BRANCH" ]]; then
        BASE_BRANCH=$(detect_base_branch)
    fi

    # Analyze commits
    git fetch origin "$BASE_BRANCH" 2>&1 || log "${YELLOW}⚠${NC} Fetch failed"

    local commits_output
    commits_output=$(git log "origin/$BASE_BRANCH..HEAD" --format='{"hash":"%H","short":"%h","subject":"%s","body":"%b","author":"%an","date":"%ai"}' 2>/dev/null || echo "")

    COMMIT_COUNT=$(git rev-list --count "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo "0")

    if [[ -n "$commits_output" ]]; then
        COMMITS_JSON=$(echo "$commits_output" | jq -s '.' 2>/dev/null || echo "[]")
    else
        COMMITS_JSON="[]"
    fi

    # Get diff stats
    DIFF_STAT=$(git diff "origin/$BASE_BRANCH...HEAD" --stat 2>/dev/null || echo "")
    FILES_CHANGED=$(git diff "origin/$BASE_BRANCH...HEAD" --numstat 2>/dev/null | wc -l)
    LINES_ADDED=$(git diff "origin/$BASE_BRANCH...HEAD" --numstat 2>/dev/null | awk '{sum+=$1} END {print sum}')
    LINES_REMOVED=$(git diff "origin/$BASE_BRANCH...HEAD" --numstat 2>/dev/null | awk '{sum+=$2} END {print sum}')

    local files_output
    files_output=$(git diff "origin/$BASE_BRANCH...HEAD" --numstat 2>/dev/null | awk '{print "{\"file\":\""$3"\",\"added\":"$1",\"removed\":"$2"}"}' || echo "")

    if [[ -n "$files_output" ]]; then
        FILES_JSON=$(echo "$files_output" | jq -s '.' 2>/dev/null || echo "[]")
    else
        FILES_JSON="[]"
    fi

    # Identify issue
    if [[ "$CURRENT_BRANCH" =~ ([0-9]+) ]]; then
        ISSUE_NUMBER="${BASH_REMATCH[1]}"
    else
        local issue_refs
        issue_refs=$(git log "origin/$BASE_BRANCH..HEAD" --format="%s %b" | sed -n 's/.*#\([0-9]\+\).*/\1/p' | head -1 || echo "")
        ISSUE_NUMBER="$issue_refs"
    fi

    # Generate title from latest commit
    PR_TITLE=$(git log -1 --format="%s" 2>/dev/null || echo "$CURRENT_BRANCH")

    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "analyze",
  "platform": "$PLATFORM",
  "current_branch": "$CURRENT_BRANCH",
  "base_branch": "$BASE_BRANCH",
  "pr_title": "$PR_TITLE",
  "issue_number": "${ISSUE_NUMBER}",
  "commit_count": $COMMIT_COUNT,
  "files_changed": $FILES_CHANGED,
  "lines_added": $LINES_ADDED,
  "lines_removed": $LINES_REMOVED,
  "commits": $COMMITS_JSON,
  "files": $FILES_JSON,
  "diff_stat": $(echo "$DIFF_STAT" | jq -Rs .),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Analysis complete"
}

# Section 2: Push branch
#
# Handles pre-push hooks that mutate tracked files (e.g., eslint --fix,
# prettier, rustfmt). Such hooks produce a dirty tree after push whose
# changes are NOT in the pushed commits. We detect that by diffing the
# working-tree state before/after the push, auto-commit the hook-produced
# modifications, and re-push. Cap at 2 retry cycles to avoid loops.
section_push() {
    log "${BLUE}Pushing Branch${NC}"

    if [[ -z "$CURRENT_BRANCH" ]]; then
        CURRENT_BRANCH=$(git branch --show-current)
    fi

    local max_attempts=3
    local attempt=1
    local pushed=0

    while [[ $attempt -le $max_attempts ]]; do
        # Snapshot tracked-file state BEFORE push. Only tracked modifications
        # (`git diff --name-only`) are relevant — untracked files aren't hook
        # output we'd want to auto-commit.
        local before_status
        before_status=$(git diff --name-only 2>/dev/null | sort -u || echo "")

        if git push -u origin "$CURRENT_BRANCH" 2>&1; then
            pushed=1
        else
            exit_with_json "error" "Failed to push branch" "Branch: $CURRENT_BRANCH (attempt $attempt)"
        fi

        # Snapshot AFTER push to detect hook mutations.
        local after_status
        after_status=$(git diff --name-only 2>/dev/null | sort -u || echo "")

        # Files newly-dirty post-push are hook output. If none, we're done.
        local hook_modified
        hook_modified=$(comm -13 <(printf '%s\n' "$before_status") <(printf '%s\n' "$after_status") | sed '/^$/d' || echo "")

        if [[ -z "$hook_modified" ]]; then
            log "${GREEN}✓${NC} Branch pushed"
            break
        fi

        # Hook rewrote tracked files — commit them so the PR is coherent.
        local file_count
        file_count=$(printf '%s\n' "$hook_modified" | wc -l | tr -d ' ')
        log "${YELLOW}⚠${NC} Pre-push hook modified $file_count file(s); committing and re-pushing"

        # Stage only the files the hook touched (avoid sweeping up unrelated dirt).
        while IFS= read -r f; do
            [[ -n "$f" ]] && git add -- "$f"
        done <<< "$hook_modified"

        if ! git diff --cached --quiet; then
            git commit -m "chore: apply pre-push hook fixes" 2>&1 || {
                exit_with_json "error" "Failed to commit pre-push hook fixes" "Files: $hook_modified"
            }
        fi

        attempt=$((attempt + 1))
    done

    if [[ $pushed -eq 0 ]]; then
        exit_with_json "error" "Push did not complete after $max_attempts attempts" "Branch: $CURRENT_BRANCH"
    fi

    # If we looped (i.e., made hook-fix commits) the analysis is now stale —
    # refresh commit/diff counts so the PR description reflects reality.
    if [[ $attempt -gt 1 ]] && [[ "$SECTION" == "full" ]]; then
        log "${BLUE}Re-analyzing after hook-fix commit(s)${NC}"
        section_analyze
    fi

    if [[ "$SECTION" == "push" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "push",
  "current_branch": "$CURRENT_BRANCH",
  "remote": "origin",
  "hook_fix_attempts": $((attempt - 1)),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Push complete"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --push) SECTION="push"; shift ;;
            --create) SECTION="create"; shift ;;
            --full) SECTION="full"; shift ;;
            --base)
                BASE_BRANCH="$2"
                shift 2
                ;;
            *) shift ;;
        esac
    done

    # Execute sections
    case "$SECTION" in
        analyze)
            section_analyze
            ;;
        push)
            section_push
            ;;
        create)
            # PR creation goes through the git adapter (git_pr_create
            # from scripts/lib/git-api.sh) so the caller doesn't need
            # to know which platform is active.
            exit_with_json "success" "Use git_pr_create via the git adapter (or your platform's CLI) to create the PR"
            ;;
        full)
            section_analyze
            section_push

            # Return complete data for LLM to generate PR description
            local json=$(cat <<EOF
{
  "status": "ready_for_description",
  "platform": "$PLATFORM",
  "current_branch": "$CURRENT_BRANCH",
  "base_branch": "$BASE_BRANCH",
  "pr_title": "$PR_TITLE",
  "issue_number": "${ISSUE_NUMBER}",
  "commit_count": $COMMIT_COUNT,
  "files_changed": $FILES_CHANGED,
  "lines_added": $LINES_ADDED,
  "lines_removed": $LINES_REMOVED,
  "commits": $COMMITS_JSON,
  "files": $FILES_JSON,
  "diff_stat": $(echo "$DIFF_STAT" | jq -Rs .),
  "next_steps": [
    "LLM generates PR description from commit data",
    "LLM creates PR via git_pr_create from lib/git-api.sh with title='$PR_TITLE' and base='$BASE_BRANCH'"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

main "$@"

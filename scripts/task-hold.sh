#!/usr/bin/env bash
set -euo pipefail

# task-hold.sh - Put task on hold while preserving work and branch
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-hold.sh [--json|--raw] [--full|--section] [flags]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --identify:  Identify task from .current-task or input
#   --update:    Update task document with hold information
#   --commit:    Commit changes and merge to main
#   --sync:      Update external systems (GitHub/GitLab)
#   --full:      Run all sections end-to-end (default)
#
# Hold Detail Flags (required for --full or --update when non-interactive):
#   --hold-reason TEXT       Reason for hold (e.g., "Switching to higher priority work")
#   --waiting-on TEXT        Who/what we're waiting on
#   --expected-date DATE     Expected response date (YYYY-MM-DD or "unknown")
#   --needed-info TEXT       What information/response is needed (optional)
#   --resume-context TEXT    Context to remember when resuming (optional)
#   --task-id ID             Task ID to put on hold (optional, uses .current-task if omitted)
#
# Workflow:
#   1. LLM calls: script.sh --json --full --hold-reason "..." --waiting-on "..." --expected-date "..."
#   2. If merge conflicts: Returns JSON with conflict details
#   3. LLM resolves conflicts using Read/Edit tools
#   4. LLM continues: script.sh --json --commit (resume from commit section)
#
# Features:
#   - Non-interactive when all hold detail flags provided (LLM-friendly)
#   - Falls back to interactive prompts when flags omitted (human-friendly)
#   - LLM intervention at merge conflicts (only when needed)
#   - --raw mode for debugging when --json insufficient

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom next_action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        needs_external_sync)  echo "sync_external" ;;
        conflict)             echo "resolve_conflicts" ;;
        needs_decision)       echo "confirm_action" ;;
        *)                    echo "fix_error" ;;
    esac
}

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/load-profile.sh"
source "${SCRIPT_DIR}/lib/task-api.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, identify, update, commit, sync

# Task metadata
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
TASK_SLUG=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""
DOCS_DIR=""
RANGE_FOLDER=""

# Hold details
HOLD_REASON=""
WAITING_ON=""
EXPECTED_DATE=""
NEEDED_INFO=""
RESUME_CONTEXT=""

# External system identifiers
ISSUE_NUMBER=""
ISSUE_ID=""
ASANA_GID=""

# Warnings accumulated across sections (surfaced in section_sync output)
WARNINGS=()

# Summary document
SUMMARY_FILENAME=""

# Status flags
EXTERNAL_UPDATED=false
SHOULD_SYNC_ASANA=false
BRANCH_LOCAL=false
BRANCH_REMOTE=false
MERGED_TO_MAIN=false

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Identify task
section_identify() {
    log "${BLUE}Identifying Task${NC}"

    local input="$1"

    # Try explicit input first
    if [[ -n "$input" ]]; then
        if [[ "$input" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            # Input is task ID
            TASK_ID=$(normalize_task_id "$input")
            TASK_DOC=$(find_primary "$TASK_ID")

            if [[ -z "$TASK_DOC" ]]; then
                exit_with_json "error" "No primary task found for task ID $TASK_ID"
            fi
            log "${GREEN}✓${NC} Found task by ID: $(basename "$TASK_DOC")"
        else
            # Try to find by path or identifier
            TASK_DOC=$(find docs/active -name "*-TSK-*.md" -o -name "*-INC-*.md" 2>/dev/null | grep "$input" | head -1 || true)
            if [[ -n "$TASK_DOC" ]]; then
                log "${GREEN}✓${NC} Found task by ID: $(basename "$TASK_DOC")"
            fi
        fi
    fi

    # Fall back to .current-task if no explicit input or input didn't resolve
    if [[ -z "$TASK_DOC" ]] && load_current_task; then
        TASK_DOC="$CT_TASK_DOC"
        CURRENT_BRANCH="$CT_BRANCH"
        ASANA_GID="$CT_ASANA_GID"

        if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]]; then
            log "${GREEN}✓${NC} Found current task: $(basename "$TASK_DOC")"
        else
            TASK_DOC=""
        fi
    fi

    # Validate task document exists
    if [[ ! -f "$TASK_DOC" ]]; then
        exit_with_json "error" "Task document not found" "" \
            "\"usage\": \"task-hold.sh [task_id|task_doc_path]\""
    fi

    # Extract metadata
    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
    TASK_TITLE=$(get_doc_title "$TASK_DOC")
    TASK_SLUG=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-\|-$//' | cut -c1-40)

    # Get current branch if not already set
    if [[ -z "$CURRENT_BRANCH" ]]; then
        CURRENT_BRANCH=$(git branch --show-current)
    fi

    # Get default branch
    DEFAULT_BRANCH=$(get_default_branch)

    # Get docs directory
    DOCS_DIR=$(find_docs_dir)

    # Extract range folder
    RANGE_FOLDER=$(basename "$(dirname "$TASK_DOC")")

    log "${GREEN}✓${NC} Task identified: $TASK_ID - $TASK_TITLE"

    if [[ "$SECTION" == "identify" ]]; then
        exit_with_json "success" "Task identified" "" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_title\": \"$TASK_TITLE\"," \
            "\"task_doc\": \"$TASK_DOC\"," \
            "\"branch\": \"$CURRENT_BRANCH\"," \
            "\"default_branch\": \"$DEFAULT_BRANCH\""
    fi
}

# Validate hold information. Fails with exit_with_json on missing/invalid data.
# Called after section_gather to enforce quality regardless of entry mode (flags vs interactive).
section_validate() {
    log "${BLUE}Validating Hold Information${NC}"

    local issues=()

    # Hold reason must be present and meaningful
    if [[ -z "$HOLD_REASON" ]]; then
        issues+=("hold_reason is required — what are we waiting for?")
    elif [[ ${#HOLD_REASON} -lt 20 ]]; then
        issues+=("hold_reason is too short (${#HOLD_REASON} chars) — provide at least 20 chars explaining why the task is on hold")
    fi

    # Waiting-on must identify someone/something concrete
    if [[ -z "$WAITING_ON" ]] || [[ "$WAITING_ON" == "External response" ]]; then
        issues+=("waiting_on is required — name the person/team/vendor/system blocking progress (generic 'External response' is not enough)")
    fi

    # Expected date: either a valid future ISO date OR the literal string "unknown"
    if [[ -z "$EXPECTED_DATE" ]]; then
        issues+=("expected_date is required — provide YYYY-MM-DD or 'unknown'")
    elif [[ "$EXPECTED_DATE" != "unknown" ]]; then
        if ! [[ "$EXPECTED_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            issues+=("expected_date '$EXPECTED_DATE' is not valid — use YYYY-MM-DD or 'unknown'")
        else
            # Must be today or future (portable: compare as strings since ISO dates are lexicographic)
            local today
            today=$(date -u +"%Y-%m-%d")
            if [[ "$EXPECTED_DATE" < "$today" ]]; then
                issues+=("expected_date '$EXPECTED_DATE' is in the past — use today, a future date, or 'unknown'")
            fi
        fi
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        local joined
        joined=$(printf '%s\n' "${issues[@]}")
        local json_issues
        json_issues=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
        exit_with_json "error" "Hold information validation failed" "$joined" \
            "\"reason\": \"invalid_hold_input\"," \
            "\"issues\": $json_issues"
    fi

    log "${GREEN}✓${NC} Hold information valid"
}

# Section 2: Gather hold information (flags or interactive fallback)
section_gather() {
    log "${BLUE}Gathering Hold Information${NC}"

    # If hold details already provided via flags, just apply defaults and return.
    # Validation happens in section_validate regardless of entry mode.
    if [[ -n "$HOLD_REASON" ]]; then
        WAITING_ON="${WAITING_ON:-"External response"}"
        EXPECTED_DATE="${EXPECTED_DATE:-"unknown"}"
        NEEDED_INFO="${NEEDED_INFO:-"Additional information needed"}"
        RESUME_CONTEXT="${RESUME_CONTEXT:-"See task document for details"}"
        log "${GREEN}✓${NC} Hold information provided via flags"
        return 0
    fi

    # Interactive fallback when no flags provided
    echo ""
    echo "Task: $TASK_TITLE"
    echo "Task ID: $TASK_ID"
    echo ""
    echo "What are we waiting for?"
    echo ""
    echo "Common reasons:"
    echo "  1. Waiting for customer response"
    echo "  2. Waiting for external vendor"
    echo "  3. Waiting for design/mockups"
    echo "  4. Waiting for requirements clarification"
    echo "  5. Waiting for infrastructure/access"
    echo "  6. Blocked by another team"
    echo "  7. Waiting for approval"
    echo "  8. Other (specify)"
    echo ""
    read -p "Reason: " HOLD_REASON

    echo ""
    echo "Hold Details"
    echo "════════════════════════════════════════"
    echo ""

    read -p "Describe what we're waiting for: " NEEDED_INFO
    read -p "Who are we waiting on? (person/team/company): " WAITING_ON
    read -p "Expected response by (YYYY-MM-DD, or 'unknown'): " EXPECTED_DATE
    read -p "Any context to remember when resuming?: " RESUME_CONTEXT

    # Set defaults
    NEEDED_INFO="${NEEDED_INFO:-"Additional information needed"}"
    WAITING_ON="${WAITING_ON:-"External response"}"
    EXPECTED_DATE="${EXPECTED_DATE:-"unknown"}"
    RESUME_CONTEXT="${RESUME_CONTEXT:-"See task document for details"}"

    log "${GREEN}✓${NC} Hold information captured"
}

# Section 3: Update task document and create summary
section_update() {
    log "${BLUE}Updating Documentation${NC}"

    # Get work summary
    local commit_count=$(git log --oneline "${DEFAULT_BRANCH}..HEAD" 2>/dev/null | wc -l || echo "0")
    local files_stat=$(git diff --stat "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "No changes yet")

    # Append hold information to task document
    cat >> "$TASK_DOC" << EOF

---

## Task On Hold

**Status**: On Hold
**Put On Hold**: $(date -Iseconds)
**Branch**: ${CURRENT_BRANCH}

### Hold Reason
${HOLD_REASON}

### Waiting On
**Who/What**: ${WAITING_ON}
**Expected Response**: ${EXPECTED_DATE}

### What We Need
${NEEDED_INFO}

### Work Completed So Far
${commit_count} commits on branch ${CURRENT_BRANCH}

**Files Changed**:
\`\`\`
${files_stat}
\`\`\`

### Context for Resumption
${RESUME_CONTEXT}

### Next Steps When Resumed
1. Review response/information received
2. Continue work from branch: ${CURRENT_BRANCH}
3. Check git log for work completed so far
4. Resume implementation

---

**Hold Timestamp**: $(date -Iseconds)
**Branch Preserved**: ${CURRENT_BRANCH}
**Resume Command**: \`/task-start ${TASK_ID}\` or \`git checkout ${CURRENT_BRANCH}\`
EOF

    git add "$TASK_DOC"

    # Update document index
    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
    git add docs/DOCUMENT-INDEX.md 2>/dev/null || true
    git add docs/SEQUENCE-TRACKER.md 2>/dev/null || true

    # Create summary document
    local datetime=$(date +%y%m%d%H%M)
    SUMMARY_FILENAME="${TASK_ID}-${datetime}-SUM-${TASK_SLUG}-onhold.md"
    local summary_path="${DOCS_DIR}/active/${RANGE_FOLDER}/${SUMMARY_FILENAME}"

    local files_count=$(git diff --stat "${DEFAULT_BRANCH}..${CURRENT_BRANCH}" 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")

    cat > "$summary_path" << EOF
# Summary: ${TASK_TITLE} (On Hold)

**Work Item**: ${TASK_ID}
**Created**: $(date -Iseconds)
**Type**: Summary
**Related To**: ${TASK_ID}-*-TSK-*.md
**Audience**: Team/All-hands
**Summary Type**: On Hold Status

---

## Purpose

Status summary for work item ${TASK_ID} which has been placed on hold.

---

## Executive Summary

Work item ${TASK_ID} (${TASK_TITLE}) has been placed on hold while waiting for ${WAITING_ON}. Expected response by ${EXPECTED_DATE}.

---

## Situation

**What Happened**:
Work in progress on ${TASK_TITLE} was paused to wait for external input/dependencies.

**Why It Matters**:
Cannot proceed without the required response/information.

**Timeline**:
- Put on Hold: $(date -Iseconds)
- Expected Response: ${EXPECTED_DATE}

---

## Current Status

**On Hold**:
- Reason: ${HOLD_REASON}
- Waiting On: ${WAITING_ON}
- Needed: ${NEEDED_INFO}
- Expected: ${EXPECTED_DATE}

**Work Completed**:
- Branch: ${CURRENT_BRANCH}
- Commits: ${commit_count}
- Files Changed: ${files_count}

---

## Context for Resumption

### What We're Waiting For
${NEEDED_INFO}

### Branch Information
- **Name**: ${CURRENT_BRANCH}
- **Commits**: ${commit_count}
- **Files**: ${files_count}

### Next Steps When Resumed
1. Review response/information from ${WAITING_ON}
2. Check out branch: ${CURRENT_BRANCH}
3. Continue implementation
4. Complete remaining acceptance criteria

---

## Expected Timeline

**When Response Received**:
- Unblock date: ${EXPECTED_DATE}
- Estimated resume time: After response received

---

## Related Documents

**For More Detail, See**:
- TSK: ${TASK_ID}-*-TSK-*.md
- Branch: ${CURRENT_BRANCH}

---

**On Hold Since**: $(date -Iseconds)
**Status**: ⏸️ On Hold
**Expected Unblock**: ${EXPECTED_DATE}
EOF

    git add "$summary_path"

    log "${GREEN}✓${NC} Documentation updated"

    if [[ "$SECTION" == "update" ]]; then
        exit_with_json "success" "Task document and summary updated" "" \
            "\"task_doc\": \"$TASK_DOC\"," \
            "\"summary_doc\": \"$SUMMARY_FILENAME\""
    fi
}

# Section 4a: Commit changes locally (no merge, no push).
# Separated from merge so that external systems (Asana) can be synced BEFORE
# the irreversible merge-to-main + push. If Asana sync fails, we can abort
# without having modified main or pushed anything.
section_commit() {
    log "${BLUE}Committing Changes (local only)${NC}"

    # Commit changes
    local commit_msg="docs(task-hold): put work item ${TASK_ID} on hold

Task: ${TASK_TITLE}
Reason: ${HOLD_REASON}
Waiting on: ${WAITING_ON}
Expected: ${EXPECTED_DATE}

Updated task document with hold information and context for resumption.
Created summary document. Branch ${CURRENT_BRANCH} preserved for later continuation."

    # Distinguish "nothing to commit" (benign) from "commit hook failed" (fatal).
    # Previously both were swallowed with a single warning, so a hook failure
    # left the staged docs uncommitted while the script proceeded to sync.
    if git diff --cached --quiet; then
        log "${BLUE}ℹ${NC} Nothing staged to commit (already committed?)"
    elif ! git commit -m "$commit_msg" >/dev/null 2>&1; then
        # Capture commit error for the JSON envelope; trap will unstage on exit.
        local commit_err
        commit_err=$(git commit -m "$commit_msg" 2>&1 || true)
        exit_with_json "error" "Failed to commit hold documentation" \
            "${commit_err}" \
            "\"branch\": \"$CURRENT_BRANCH\""
    fi

    log "${GREEN}✓${NC} Commit created on ${CURRENT_BRANCH}"

    if [[ "$SECTION" == "commit" ]]; then
        exit_with_json "success" "Changes committed locally — ready for external sync" "" \
            "\"branch\": \"$CURRENT_BRANCH\"," \
            "\"merged_to_main\": false," \
            "\"next_steps\": [\"Sync external systems (Asana, GitHub, GitLab)\", \"Then run: task-hold.sh --json --merge\"]"
    fi
}

# Section 4b: Preserve feature branch on remote.
#
# IMPORTANT: This section used to *merge* the WIP feature branch into the
# default branch (main) and push main. That was destructive — putting a task
# on hold should preserve in-progress work for later resumption, not integrate
# unfinished work into the trunk. The documented contract ("Branch preserved
# for resumption") was directly contradicted by the implementation.
#
# Now we only push the feature branch itself so it survives if the local
# worktree is later removed. The default branch is never touched.
section_merge() {
    log "${BLUE}Preserving Feature Branch${NC}"

    MERGED_TO_MAIN=false

    # Push feature branch to preserve it remotely. We deliberately do NOT
    # `git checkout $DEFAULT_BRANCH` — that would risk losing uncommitted state
    # if the working tree isn't clean, and worktree-mode callers want to stay
    # on the feature branch for `task-resume` to find later.
    if git push -u origin "${CURRENT_BRANCH}" >/dev/null 2>&1; then
        BRANCH_REMOTE=true
        log "${GREEN}✓${NC} Branch ${CURRENT_BRANCH} preserved on remote"
    else
        log "${YELLOW}⚠${NC} Failed to push ${CURRENT_BRANCH} to remote (check permissions / network)"
    fi

    # Verify branch exists locally
    if git show-ref --verify --quiet "refs/heads/${CURRENT_BRANCH}"; then
        BRANCH_LOCAL=true
        log "${GREEN}✓${NC} Branch ${CURRENT_BRANCH} preserved locally"
    fi

    if [[ "$SECTION" == "merge" ]]; then
        exit_with_json "success" "Feature branch preserved" "" \
            "\"branch\": \"$CURRENT_BRANCH\"," \
            "\"merged_to_main\": false," \
            "\"branch_local\": $BRANCH_LOCAL," \
            "\"branch_remote\": $BRANCH_REMOTE"
    fi
}

# Section 5: Sync external systems
section_sync() {
    log "${BLUE}Syncing External Systems${NC}"

    # Load task adapter. Distinguish "no backend configured" (benign — local-only
    # task) from "adapter load failed" (real error — surface as warning so caller
    # can see it instead of getting a quiet EXTERNAL_UPDATED=false).
    local _adapter_backend
    _adapter_backend=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null || echo "")
    if [[ -n "$_adapter_backend" && "$_adapter_backend" != "none" ]]; then
        if ! load_task_adapter 2>/dev/null; then
            WARNINGS+=("Task adapter load failed for backend '$_adapter_backend' — external hold-sync skipped")
            log "${YELLOW}⚠${NC} Could not load task adapter for $_adapter_backend"
        fi
    fi

    # Extract issue numbers from task document (used only for logging; adapter uses TASK_ID)
    ISSUE_NUMBER=$(sed -n 's/.*GitHub.*Issue.*#\([0-9]\+\).*/\1/p' "$TASK_DOC" 2>/dev/null | head -1 || echo "")
    ISSUE_ID=$(sed -n 's/.*GitLab.*Issue.*#\([0-9]\+\).*/\1/p' "$TASK_DOC" 2>/dev/null | head -1 || echo "")

    # Determine the task ID to use with the adapter: prefer explicit backend IDs
    # extracted from the document; fall back to TASK_ID (our V4 hex ID).
    local adapter_task_id="${ISSUE_NUMBER:-${ISSUE_ID:-$TASK_ID}}"

    # Use adapter to put task on hold and add a comment (works for any backend)
    if declare -f task_hold &>/dev/null && [[ -n "$adapter_task_id" ]]; then
        local hold_comment="Task put on hold.

Reason: ${HOLD_REASON}
Waiting on: ${WAITING_ON}
Expected response: ${EXPECTED_DATE}
Needed: ${NEEDED_INFO}

Branch ${CURRENT_BRANCH} preserved. Will resume when response received."

        task_hold "$adapter_task_id" "$HOLD_REASON" "$WAITING_ON" 2>/dev/null || true
        task_comment "$adapter_task_id" "$hold_comment" 2>/dev/null || true

        log "${GREEN}✓${NC} External task #${adapter_task_id} marked as on-hold via adapter"
        EXTERNAL_UPDATED=true
    else
        log "${BLUE}ℹ${NC} No task adapter available — skipping external sync"
    fi

    # Check for Asana integration requiring additional LLM-driven sync
    local backend
    backend=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null || true)
    local sync_on_hold
    sync_on_hold=$(yaml_get '.task_management.asana.sync_on_operations[] | select(. == "hold")' PROJECT.yaml 2>/dev/null || true)

    if [[ "$backend" == "asana" ]] && [[ -n "$sync_on_hold" ]]; then
        SHOULD_SYNC_ASANA=true
        log "${GREEN}✓${NC} Asana sync enabled (adapter handles REST; LLM may add extra MCP steps)"
    else
        log "${BLUE}ℹ${NC} Asana sync via LLM not required"
    fi

    if [[ "$SECTION" == "sync" ]]; then
        exit_with_json "success" "External systems synced" "" \
            "\"external_updated\": $EXTERNAL_UPDATED," \
            "\"should_sync_asana\": $SHOULD_SYNC_ASANA," \
            "\"asana_gid\": \"$ASANA_GID\""
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    local task_input=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                OUTPUT_MODE="json"
                shift
                ;;
            --raw)
                OUTPUT_MODE="raw"
                shift
                ;;
            --full)
                SECTION="full"
                shift
                ;;
            --identify)
                SECTION="identify"
                shift
                ;;
            --update)
                SECTION="update"
                shift
                ;;
            --commit)
                SECTION="commit"
                shift
                ;;
            --merge)
                SECTION="merge"
                shift
                ;;
            --sync)
                SECTION="sync"
                shift
                ;;
            --validate)
                SECTION="validate"
                shift
                ;;
            --task-id)
                task_input="$2"
                shift 2
                ;;
            --hold-reason)
                HOLD_REASON="$2"
                shift 2
                ;;
            --waiting-on)
                WAITING_ON="$2"
                shift 2
                ;;
            --expected-date)
                EXPECTED_DATE="$2"
                shift 2
                ;;
            --needed-info)
                NEEDED_INFO="$2"
                shift 2
                ;;
            --resume-context)
                RESUME_CONTEXT="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 2
                ;;
        esac
    done

    # Trap: if section_update stages files into the index but a later step
    # fails (commit hook, push failure, interrupt), the staging area is left
    # dirty. A retry sees a poisoned index. Unstage on non-success exit.
    _HOLD_SUCCESS=0
    _hold_cleanup() {
        local rc=$?
        if [[ $rc -ne 0 ]] && [[ $_HOLD_SUCCESS -eq 0 ]]; then
            # Only unstage if there's anything staged AND we're in a git repo
            if git rev-parse --git-dir >/dev/null 2>&1; then
                if ! git diff --cached --quiet 2>/dev/null; then
                    log "${YELLOW}⚠${NC} task-hold failed — unstaging files so retry sees clean index"
                    git reset HEAD -- . >/dev/null 2>&1 || true
                fi
            fi
        fi
        return $rc
    }
    trap _hold_cleanup EXIT

    # Always run identify first (needed for all sections)
    section_identify "$task_input"

    # If only identify section requested, already exited above

    # Run gather only for full workflow (not for section-specific runs)
    if [[ "$SECTION" == "full" ]]; then
        section_gather
        section_validate
    fi

    # Run remaining sections based on SECTION flag.
    # Full flow: update → commit_local → sync_external → [LLM does Asana] → merge
    # This ordering ensures Asana status is flipped BEFORE the irreversible merge/push.
    case "$SECTION" in
        full)
            section_update
            section_commit           # local commit only — NO merge yet
            section_sync             # returns sync hints (should_sync_asana, etc.)

            # If Asana sync is required, pause here and return to LLM.
            # The LLM handles Asana via MCP, then calls --merge to finalize.
            if [[ "$SHOULD_SYNC_ASANA" == "true" ]]; then
                exit_with_json "needs_external_sync" \
                    "Task document committed — sync Asana before merging" \
                    "LLM: update Asana status to 'Hold' and add a comment via MCP. On success, run task-hold.sh --json --merge" \
                    "\"task_id\": \"$TASK_ID\"," \
                    "\"task_title\": \"$TASK_TITLE\"," \
                    "\"task_doc\": \"$TASK_DOC\"," \
                    "\"branch\": \"$CURRENT_BRANCH\"," \
                    "\"hold_reason\": \"$HOLD_REASON\"," \
                    "\"waiting_on\": \"$WAITING_ON\"," \
                    "\"expected_date\": \"$EXPECTED_DATE\"," \
                    "\"needed_info\": \"$NEEDED_INFO\"," \
                    "\"should_sync_asana\": true," \
                    "\"asana_gid\": \"$ASANA_GID\"," \
                    "\"external_updated\": $EXTERNAL_UPDATED," \
                    "\"next_steps\": [\"Verify adapter sync succeeded (external_updated flag)\", \"Apply any additional Asana custom-field updates if required\", \"Run: task-hold.sh --json --merge\"]"
            fi

            # No Asana sync needed → proceed directly to branch preservation
            section_merge
            _HOLD_SUCCESS=1
            ;;
        validate)
            section_validate
            ;;
        update)
            section_update
            ;;
        commit)
            section_commit
            ;;
        merge)
            section_merge
            ;;
        sync)
            section_sync
            ;;
    esac

    # Full workflow complete - return success with all data
    if [[ "$SECTION" == "full" ]] || [[ "$SECTION" == "merge" ]]; then
        exit_with_json "success" "Task put on hold successfully" "" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_title\": \"$TASK_TITLE\"," \
            "\"task_doc\": \"$TASK_DOC\"," \
            "\"branch\": \"$CURRENT_BRANCH\"," \
            "\"hold_reason\": \"$HOLD_REASON\"," \
            "\"waiting_on\": \"$WAITING_ON\"," \
            "\"expected_date\": \"$EXPECTED_DATE\"," \
            "\"needed_info\": \"$NEEDED_INFO\"," \
            "\"summary_created\": \"$SUMMARY_FILENAME\"," \
            "\"merged_to_main\": $MERGED_TO_MAIN," \
            "\"branch_local\": $BRANCH_LOCAL," \
            "\"branch_remote\": $BRANCH_REMOTE," \
            "\"external_updated\": $EXTERNAL_UPDATED," \
            "\"should_sync_asana\": $SHOULD_SYNC_ASANA," \
            "\"asana_gid\": \"$ASANA_GID\"," \
            "\"resume_command\": \"/task-start $TASK_ID\""
    fi
}

# Run main function
main "$@"

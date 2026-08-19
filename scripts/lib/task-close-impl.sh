#!/usr/bin/env bash
# task-close-impl.sh — implementation of the task-close lifecycle.
#
# Consolidates the five previous task-close-{identify,complete,defer,
# sync,cleanup}.sh fragments into one module. The orchestrator
# scripts/task-close.sh sources this file and wires its section
# functions to flags.
#
# Section functions exported (in execution order):
#   section_identify     — locate task doc, parse external tracking
#   section_complete     — completion path (final state writer)
#   section_defer        — defer-instead-of-complete path
#   section_extract_summary_data — gather data for the SUM doc
#   section_create_summary — write the SUM doc (was task-close-sync.sh)
#   section_pre_verify   — pre-merge verification
#   section_cleanup      — branch + worktree cleanup
#
# Helper functions exported (used by tests and the orchestrator):
#   print_header, write_close_state, write_close_verified,
#   write_close_checkpoint, has_close_checkpoint, read_close_state,
#   detect_source_branch, resolve_merge_target, run_pre_merge_verify
#
# Don't source this file directly — go through scripts/task-close.sh.

[[ -n "${_TASK_CLOSE_IMPL_LOADED:-}" ]] && return 0
_TASK_CLOSE_IMPL_LOADED=1


# ============================================================
# Section: task-close-identify
# ============================================================

# Sourced by task-close.sh — shares globals, no standalone execution


print_header() {
    log "${CYAN}$1${NC}"
    log "$(printf '%.0s═' {1..60})"
}

CLOSE_STATE_FILE=".task-close-state"

# Write lockfile with resolved branch targets (prevents cascade on retry).
# Preserves existing pre_verified_sha if already present in the file.
write_close_state() {
    local task_id="$1"
    local feature_branch="$2"
    local target_branch="$3"

    # Preserve pre_verified_sha across rewrites (set by write_close_verified)
    local existing_verified_sha=""
    if [[ -f "$CLOSE_STATE_FILE" ]]; then
        existing_verified_sha=$(jq -r '.pre_verified_sha // empty' "$CLOSE_STATE_FILE" 2>/dev/null || echo "")
    fi

    # Detect worktree path for checkpoint recovery (DSN Decision 8)
    local worktree_path_val=""
    if declare -f get_worktree_path &>/dev/null; then
        worktree_path_val=$(get_worktree_path "$task_id" 2>/dev/null || echo "")
    fi

    jq -n \
        --arg task_id "$task_id" \
        --arg feature_branch "$feature_branch" \
        --arg target_branch "$target_branch" \
        --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg verified_sha "$existing_verified_sha" \
        --arg worktree_path "$worktree_path_val" \
        '{task_id: $task_id, feature_branch: $feature_branch, target_branch: $target_branch, created: $created}
         + (if $verified_sha != "" then {pre_verified_sha: $verified_sha} else {} end)
         + (if $worktree_path != "" then {worktree_path: $worktree_path} else {} end)' \
        > "$CLOSE_STATE_FILE"

    # Note: .task-close-state is intentionally NOT gitignored.
    # It persists through the close process for retry safety.
    # Cleanup deletes it on successful close. If present on next
    # task-start/task-close, it signals a previous close didn't finish.
}

# Record that pre-merge verification passed at the given SHA.
# Subsequent --cleanup calls can skip re-verification if HEAD is unchanged.
write_close_verified() {
    local verified_sha="$1"
    if [[ ! -f "$CLOSE_STATE_FILE" ]]; then
        return 1
    fi
    local tmp="${CLOSE_STATE_FILE}.tmp"
    jq --arg sha "$verified_sha" \
       --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '. + {pre_verified_sha: $sha, pre_verified_at: $ts}' \
       "$CLOSE_STATE_FILE" > "$tmp" && mv "$tmp" "$CLOSE_STATE_FILE"
}

# Record that a cleanup checkpoint has been passed. Makes --cleanup resumable:
# if the script dies between steps, a retry can skip already-completed steps.
#
# Checkpoints (in execution order):
#   target_resolved   — merge target has been locked in
#   pre_verified      — pre-merge verification passed (also set by write_close_verified)
#   merged            — squash merge into target branch succeeded
#   switched          — working tree is now on the target branch
#   docs_moved        — task docs moved from active/ to completed/ and committed
#   branch_deleted    — local (and best-effort remote) feature branch deleted
write_close_checkpoint() {
    local checkpoint="$1"
    if [[ ! -f "$CLOSE_STATE_FILE" ]]; then
        return 1
    fi
    local tmp="${CLOSE_STATE_FILE}.tmp"
    jq --arg cp "$checkpoint" \
       --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '.checkpoints = ((.checkpoints // []) + [$cp] | unique)
        | .last_checkpoint = $cp
        | .last_checkpoint_at = $ts' \
       "$CLOSE_STATE_FILE" > "$tmp" && mv "$tmp" "$CLOSE_STATE_FILE"
}

# Check whether a cleanup checkpoint has already been completed.
# Returns 0 (true) if the checkpoint exists in state, 1 (false) otherwise.
has_close_checkpoint() {
    local checkpoint="$1"
    [[ -f "$CLOSE_STATE_FILE" ]] || return 1
    jq -e --arg cp "$checkpoint" '(.checkpoints // []) | index($cp) != null' \
        "$CLOSE_STATE_FILE" >/dev/null 2>&1
}

# Read lockfile — sets LOCKED_FEATURE_BRANCH, LOCKED_TARGET_BRANCH, LOCKED_VERIFIED_SHA
# Returns 0 if lockfile exists and has branches, 1 otherwise
read_close_state() {
    LOCKED_FEATURE_BRANCH=""
    LOCKED_TARGET_BRANCH=""
    LOCKED_VERIFIED_SHA=""

    if [[ ! -f "$CLOSE_STATE_FILE" ]]; then
        return 1
    fi

    LOCKED_FEATURE_BRANCH=$(jq -r '.feature_branch // empty' "$CLOSE_STATE_FILE" 2>/dev/null)
    LOCKED_TARGET_BRANCH=$(jq -r '.target_branch // empty' "$CLOSE_STATE_FILE" 2>/dev/null)
    LOCKED_VERIFIED_SHA=$(jq -r '.pre_verified_sha // empty' "$CLOSE_STATE_FILE" 2>/dev/null)

    if [[ -z "$LOCKED_FEATURE_BRANCH" ]] || [[ -z "$LOCKED_TARGET_BRANCH" ]]; then
        return 1
    fi

    return 0
}

detect_source_branch() {
    # Explicit override via --target-branch
    if [[ -n "$MERGE_TARGET" ]]; then
        if git rev-parse --verify "$MERGE_TARGET" &>/dev/null; then
            echo "$MERGE_TARGET"
            return 0
        fi
        log "${RED}✗${NC} Specified target branch '$MERGE_TARGET' not found"
        return 1
    fi

    # Detect the parent branch via merge-base (closest fork point).
    # This correctly handles branches-off-branches — a feature branch
    # always merges back to wherever it was forked from, not necessarily
    # the default branch.
    detect_base_branch
}

section_identify() {
    print_header "Task Identification"

    # Try explicit input first
    if [[ -n "$INPUT_ARG" ]]; then
        if [[ "$INPUT_ARG" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$INPUT_ARG")
        else
            # Try to find by path or identifier
            TASK_DOC=$(find docs -name "*${INPUT_ARG}*-TSK-*.md" -o -name "*${INPUT_ARG}*-INC-*.md" 2>/dev/null | head -1 || true)
        fi
    fi

    # If we have a task ID but no doc yet, search everywhere (active + completed)
    if [[ -n "$TASK_ID" ]] && [[ -z "$TASK_DOC" ]]; then
        TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || true)
        # Also try any doc with this ID (DSN, PLN, etc.)
        if [[ -z "$TASK_DOC" ]] || [[ ! -f "$TASK_DOC" ]]; then
            TASK_DOC=$(find_by_id "$TASK_ID" 2>/dev/null | head -1 || true)
        fi
    fi

    # Fall back to .current-task
    if [[ -z "$TASK_ID" ]] && [[ -z "$TASK_DOC" ]] && load_current_task; then
        TASK_DOC="$CT_TASK_DOC"
        CURRENT_BRANCH="$CT_BRANCH"
        ASANA_GID="$CT_ASANA_GID"
        if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]]; then
            log "${GREEN}✓${NC} Found current task: $(basename "$TASK_DOC")"
        else
            TASK_DOC=""
        fi
    fi

    # Extract metadata from doc if we have one
    if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]]; then
        [[ -z "$TASK_ID" ]] && TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
        TASK_TITLE=$(get_doc_title "$TASK_DOC")
        RANGE_FOLDER=$(basename "$(dirname "$TASK_DOC")")
        log "${GREEN}✓${NC} Found doc: $(basename "$TASK_DOC")"
    fi

    # We need at least a task ID to proceed
    if [[ -z "$TASK_ID" ]]; then
        exit_with_json "error" "No task ID provided or detected" "Use: task-close.sh --task-id <ID>"
    fi

    # Derive what we can from the task ID if doc wasn't found
    if [[ -z "$TASK_TITLE" ]]; then
        # Try to derive title from branch name
        TASK_TITLE=$(git branch --show-current 2>/dev/null | sed "s|^feature/${TASK_ID}-||" | tr '-' ' ' || echo "$TASK_ID")
    fi
    TASK_SLUG=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-\|-$//' | cut -c1-40)

    # Current branch from git (not .current-task)
    if [[ -z "$CURRENT_BRANCH" ]]; then
        CURRENT_BRANCH=$(git branch --show-current)
    fi

    DEFAULT_BRANCH=$(get_default_branch)
    DOCS_DIR=$(find_docs_dir)

    # Range folder for doc moves (derive from date if not set from doc path)
    if [[ -z "$RANGE_FOLDER" ]] || [[ "$RANGE_FOLDER" == "." ]]; then
        RANGE_FOLDER=$(date +"%Y-%m")
    fi

    log "${BLUE}ℹ${NC} Work item: $TASK_ID"
    log "${BLUE}ℹ${NC} Task: $TASK_TITLE"
    log "${BLUE}ℹ${NC} Branch: $CURRENT_BRANCH"

    # Determine status (completed or deferred)
    if [[ "$AI_MODE" == "true" ]] && [[ -n "$AI_STATUS" ]]; then
        # AI mode - use provided status
        STATUS="$AI_STATUS"
    elif [[ "$SECTION" == "cleanup" ]] || [[ "$SECTION" == "extract-summary-data" ]] || [[ "$SECTION" == "create-summary" ]]; then
        # Cleanup/extract/create modes - extract status from task document
        if grep -q "^## Completion Summary" "$TASK_DOC"; then
            local completion_section=$(sed -n '/^## Completion Summary/,/^---$/p' "$TASK_DOC" | head -20)
            if echo "$completion_section" | grep -q "Status.*Completed"; then
                STATUS="completed"
            elif echo "$completion_section" | grep -q "Status.*Deferred"; then
                STATUS="deferred"
            else
                STATUS="completed"  # Default to completed if ambiguous
            fi
            log "${GREEN}✓${NC} Status extracted from task document: $STATUS"
        else
            exit_with_json "error" "No completion data found in task document" "Run --full first to collect completion data"
        fi
    elif [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo ""
        echo "Task: $TASK_TITLE"
        echo ""
        echo "Is this task:"
        echo "  1. ✓ Completed - All work done"
        echo "  2. ⏸️  Deferred - Postponed for later"
        echo ""
        read -p "Choice (1 or 2): " choice

        case "$choice" in
            1) STATUS="completed" ;;
            2) STATUS="deferred" ;;
            *)
                exit_with_json "error" "Invalid choice" "Must be 1 (completed) or 2 (deferred)"
                ;;
        esac
    else
        # In JSON mode, prompt user
        echo "Task: $TASK_TITLE" >&2
        echo "" >&2
        echo "Is this task:" >&2
        echo "  1. ✓ Completed - All work done" >&2
        echo "  2. ⏸️  Deferred - Postponed for later" >&2
        echo "" >&2
        read -p "Choice (1 or 2): " choice >&2

        case "$choice" in
            1) STATUS="completed" ;;
            2) STATUS="deferred" ;;
            *)
                exit_with_json "error" "Invalid choice" "Must be 1 (completed) or 2 (deferred)"
                ;;
        esac
    fi

    log "${GREEN}✓${NC} Status determined: $STATUS"

    # If running only this section, return now
    if [[ "$SECTION" == "identify" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "identify",
  "message": "Task identified: $TASK_TITLE",
  "task_status": "$STATUS",
  "task_id": "$TASK_ID",
  "task_doc": "$TASK_DOC",
  "task_title": "$TASK_TITLE",
  "branch": "$CURRENT_BRANCH",
  "asana_gid": "$ASANA_GID",
  "next_steps": ["Continue with: task-close.sh --json --$(echo $STATUS | sed 's/completed/complete/')"],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# ============================================================
# Section: task-close-complete
# ============================================================

# Sourced by task-close.sh — shares globals, no standalone execution


# Ensure profile accessors are available (idempotent if parent sourced it)
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/load-profile.sh"

section_complete() {
    print_header "Task Completion"

    # Verify acceptance criteria
    log "${BLUE}ℹ${NC} Verifying acceptance criteria..."

    local criteria_section=$(sed -n '/^## Acceptance Criteria/,/^##/p' "$TASK_DOC" | grep '^\s*-\s*\[.\]\s*' | sed 's/^\s*-\s*\[.\]\s*//' || true)

    if [[ -n "$criteria_section" ]]; then
        if [[ "$AI_MODE" == "true" ]]; then
            # AI mode - auto-approve all criteria
            local verified_criteria=""
            while IFS= read -r criterion; do
                if [[ -n "$criterion" ]]; then
                    verified_criteria="${verified_criteria}- [x] $criterion"$'\n'
                fi
            done <<< "$criteria_section"
            CRITERIA_STATUS="$verified_criteria"
        else
            # Interactive mode
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                echo ""
                echo "Review each criterion:" >&2
                echo "" >&2
            fi

            local all_met=true
            local verified_criteria=""

            while IFS= read -r criterion; do
                if [[ -n "$criterion" ]]; then
                    if [[ "$OUTPUT_MODE" == "raw" ]]; then
                        echo "- $criterion" >&2
                        read -p "  Completed? (y/n): " completed >&2
                    else
                        echo "- $criterion" >&2
                        read -p "  Completed? (y/n): " completed >&2
                    fi

                    if [[ "$completed" == "y" ]]; then
                        verified_criteria="${verified_criteria}- [x] $criterion"$'\n'
                    else
                        verified_criteria="${verified_criteria}- [ ] $criterion"$'\n'
                        all_met=false
                    fi
                fi
            done <<< "$criteria_section"

            CRITERIA_STATUS="$verified_criteria"

            if [[ "$all_met" != true ]]; then
                echo "" >&2
                echo "⚠️  Not all criteria are complete" >&2
                read -p "Continue marking as complete anyway? (y/n): " continue_anyway >&2

                if [[ "$continue_anyway" != "y" ]]; then
                    exit_with_json "error" "Task close aborted" "Not all acceptance criteria met"
                fi
            fi
        fi
    else
        CRITERIA_STATUS="No criteria defined"
        log "${YELLOW}⚠${NC} No acceptance criteria found"
    fi

    log "${GREEN}✓${NC} Acceptance criteria verified"

    # Capture progress and learnings
    print_header "Progress & Learnings"

    if [[ "$AI_MODE" == "true" ]]; then
        # AI mode - use provided values
        PROGRESS_SUMMARY="${AI_ACCOMPLISHED}"
        WENT_WELL="${AI_WENT_WELL}"
        CHALLENGES="${AI_CHALLENGES}"
        DO_DIFFERENTLY="${AI_DIFFERENTLY}"
        REUSABLE_PATTERNS="${AI_PATTERNS}"
    else
        # Interactive mode
        echo "What was accomplished? (1-2 sentences)" >&2
        read -p "> " PROGRESS_SUMMARY >&2

        echo "" >&2
        echo "Learnings & Notes (press Enter to skip each)" >&2
        echo "" >&2

        echo "What went well?" >&2
        read -p "> " WENT_WELL >&2

        echo "What were the challenges?" >&2
        read -p "> " CHALLENGES >&2

        echo "What would you do differently?" >&2
        read -p "> " DO_DIFFERENTLY >&2

        echo "Any reusable patterns discovered?" >&2
        read -p "> " REUSABLE_PATTERNS >&2
    fi

    log "${GREEN}✓${NC} Progress captured"

    # Update task document (if it exists in active/)
    print_header "Updating Task Document"

    if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]] && echo "$TASK_DOC" | grep -q "/active/"; then
        cat >> "$TASK_DOC" << EOF

---

## Completion Summary

**Status**: ✓ Completed
**Completed**: $(date -Iseconds)

### What Was Accomplished
${PROGRESS_SUMMARY}

### Acceptance Criteria
${CRITERIA_STATUS}

### What Went Well
${WENT_WELL:-N/A}

### Challenges
${CHALLENGES:-N/A}

### What Would You Do Differently
${DO_DIFFERENTLY:-N/A}

### Reusable Patterns
${REUSABLE_PATTERNS:-N/A}

---
EOF

        git add "$TASK_DOC" 2>/dev/null || true
        log "${GREEN}✓${NC} Task document updated"
    else
        log "${BLUE}ℹ${NC} No active task document to update (already moved or never created)"
    fi

    # Check for uncommitted changes
    local uncommitted=$(git status --porcelain | grep -v "^??" || true)
    if [[ -n "$uncommitted" ]]; then
        log "${YELLOW}⚠${NC} Uncommitted changes detected - should commit before closing"
        echo "Uncommitted changes:" >&2
        git status --short >&2
        echo "" >&2

        if [[ "$AI_MODE" != "true" ]]; then
            read -p "Continue anyway? (y/n): " continue_commit >&2
            if [[ "$continue_commit" != "y" ]]; then
                exit_with_json "error" "Uncommitted changes" "Please commit your work before closing task"
            fi
        fi
        # In AI mode, auto-continue (AI commits separately)
    fi

    # Find PR/MR
    print_header "Finding PR/MR"

    # Detect git platform
    local remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" == *"github.com"* ]]; then
        GIT_PLATFORM="github"
    elif [[ "$remote_url" == *"gitlab"* ]]; then
        GIT_PLATFORM="gitlab"
    else
        GIT_PLATFORM="unknown"
    fi

    if [[ "$GIT_PLATFORM" == "github" ]]; then
        # Find GitHub PR
        if command -v gh &> /dev/null; then
            local pr_info=$(gh pr list --head "$CURRENT_BRANCH" --json number,url,state --jq '.[0]' 2>/dev/null || echo "")
            if [[ -n "$pr_info" ]] && [[ "$pr_info" != "null" ]]; then
                PR_NUMBER=$(echo "$pr_info" | jq -r '.number')
                PR_URL=$(echo "$pr_info" | jq -r '.url')
                PR_STATE=$(echo "$pr_info" | jq -r '.state')
                log "${GREEN}✓${NC} Found PR: #$PR_NUMBER ($PR_STATE)"
            else
                log "${YELLOW}⚠${NC} No PR found for branch $CURRENT_BRANCH"
            fi
        fi
    elif [[ "$GIT_PLATFORM" == "gitlab" ]]; then
        # Find GitLab MR
        if [[ -f "$HOME/.gitlab-token" ]]; then
            local gitlab_token=$(cat "$HOME/.gitlab-token")
            local project_id=$(git remote get-url origin | sed 's#.*[:/]\(.*\)\.git#\1#' | sed 's#/#%2F#g')
            local gitlab_host=$(profile_env_get .git.instance 2>/dev/null)
            local mr_info=$(curl -s --header "PRIVATE-TOKEN: $gitlab_token" \
                "https://${gitlab_host}/api/v4/projects/${project_id}/merge_requests?source_branch=${CURRENT_BRANCH}&state=opened" \
                | jq '.[0]' 2>/dev/null || echo "")
            if [[ -n "$mr_info" ]] && [[ "$mr_info" != "null" ]]; then
                MR_NUMBER=$(echo "$mr_info" | jq -r '.iid')
                PR_URL=$(echo "$mr_info" | jq -r '.web_url')
                PR_STATE=$(echo "$mr_info" | jq -r '.state')
                log "${GREEN}✓${NC} Found MR: !$MR_NUMBER ($PR_STATE)"
            else
                log "${YELLOW}⚠${NC} No MR found for branch $CURRENT_BRANCH"
            fi
        fi
    fi

    # Extract issue/task IDs from branch name or commits
    ISSUE_NUMBER=$(echo "$CURRENT_BRANCH" | grep -oE '#[0-9]+' | head -1 || echo "")

    # Extract external tracking info from task doc
    if [[ -z "$ASANA_GID" ]]; then
        ASANA_GID=$(grep -A 20 "^## External Tracking" "$TASK_DOC" | \
                    grep "^- Task GID:" | \
                    sed 's/.*\[\?\([0-9]*\)\]\?/\1/' | \
                    tr -d '[]' | head -1 || echo "")
    fi

    # Update external systems via the task_* adapter contract.
    #
    # This block previously held raw `gh issue close` / raw `curl PUT` calls
    # against the GitLab API — bypassing the lib/task-api.sh adapter that
    # task-capture and task-hold already route through. That left the adapter
    # refactor half-applied: capture and hold went through the contract, close
    # did not. Route through `task_close` so any backend (asana / gitlab /
    # github / none) is handled uniformly.
    print_header "Updating External Systems"

    local adapter_id="${ISSUE_NUMBER:-${ISSUE_ID:-${ASANA_GID:-}}}"
    adapter_id="${adapter_id#\#}"  # strip leading # if present
    local close_comment="✅ Task completed${PR_NUMBER:+ in PR #${PR_NUMBER}}${MR_NUMBER:+ in MR !${MR_NUMBER}}"

    if [[ -z "$adapter_id" ]]; then
        log "${BLUE}ℹ${NC} No external task ID found — skipping adapter close"
    elif ! declare -f load_task_adapter >/dev/null 2>&1; then
        log "${YELLOW}⚠${NC} task-api adapter not loaded — skipping external close"
    elif ! load_task_adapter 2>/dev/null; then
        log "${YELLOW}⚠${NC} Could not load task adapter for current backend — skipping external close"
    elif declare -f task_close >/dev/null 2>&1; then
        if task_close "$adapter_id" "$close_comment" 2>/dev/null; then
            EXTERNAL_UPDATED=true
            log "${GREEN}✓${NC} Closed external task $adapter_id via adapter"
        else
            log "${YELLOW}⚠${NC} Could not close external task $adapter_id (adapter returned non-zero)"
        fi
    fi

    # Check for TxtWire work hours (Home environment only)
    if [[ "$(uname -s)" == "Linux" ]]; then
        IS_HOME=true
        local txtwire_remote=$(git remote get-url origin 2>/dev/null | grep -i "txtwire" || echo "")
        if [[ -n "$txtwire_remote" ]]; then
            IS_TXTWIRE=true

            # Estimate hours from commits
            local commit_count=$(git log "$DEFAULT_BRANCH..$CURRENT_BRANCH" --oneline | wc -l)
            local files_changed=$(git diff --name-only "$DEFAULT_BRANCH..$CURRENT_BRANCH" | wc -l)

            # Simple heuristic: 0.5h per commit + 0.1h per file
            USER_HOURS=$(echo "scale=1; ($commit_count * 0.5) + ($files_changed * 0.1)" | bc | awk '{printf "%.1f", $0}')

            # Get most recent commit date
            MOST_RECENT_DATE=$(git log -1 --format=%cd --date=format:"%m/%d" "$CURRENT_BRANCH" 2>/dev/null || date +"%m/%d")

            if [[ "$AI_MODE" == "true" ]]; then
                # AI mode - auto-log with estimated hours
                WORK_HOURS_LOGGED=true
                log "${GREEN}✓${NC} Will log $USER_HOURS hours for $MOST_RECENT_DATE (AI mode)"
            else
                # Interactive mode
                echo "" >&2
                echo "TxtWire Project Detected (Home Environment)" >&2
                echo "Estimated hours: $USER_HOURS" >&2
                echo "Date: $MOST_RECENT_DATE" >&2
                echo "" >&2
                read -p "Log work hours to Invoice Ninja? (y/n): " log_hours >&2

                if [[ "$log_hours" == "y" ]]; then
                    read -p "Hours (default: $USER_HOURS): " input_hours >&2
                    if [[ -n "$input_hours" ]]; then
                        USER_HOURS="$input_hours"
                    fi

                    read -p "Date in M/d format (default: $MOST_RECENT_DATE): " input_date >&2
                    if [[ -n "$input_date" ]]; then
                        MOST_RECENT_DATE="$input_date"
                    fi

                    WORK_HOURS_LOGGED=true
                    log "${GREEN}✓${NC} Will log $USER_HOURS hours for $MOST_RECENT_DATE"
                fi
            fi
        fi
    fi

    # Check Asana integration
    if [[ -f "PROJECT.yaml" ]]; then
        local backend=$(yaml_get '.task_management.backend' PROJECT.yaml)
        local sync_on_close=$(yaml_get '.task_management.asana.sync_on_operations[] | select(. == "close")' PROJECT.yaml)

        if [[ "$backend" == "asana" ]] && [[ -n "$sync_on_close" ]] && [[ -n "$ASANA_GID" ]]; then
            SHOULD_SYNC_ASANA=true
            log "${BLUE}ℹ${NC} Asana sync required (will be handled by LLM)"
        fi
    fi

    log "${GREEN}✓${NC} Completed task processing"

    # Get SUM document filepath + template via new-doc.sh --json (no file written)
    local sum_filepath=""
    local sum_template=""
    local sum_doc_json=""
    sum_doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type SUM --description "task-summary" --id "$TASK_ID" --json 2>/dev/null || true)
    if [[ -n "$sum_doc_json" ]]; then
        sum_filepath=$(echo "$sum_doc_json" | jq -r '.filepath // empty')
        sum_template=$(echo "$sum_doc_json" | jq -r '.template // empty')
    fi

    # Write completion data as a final progress entry in the PLN
    local plan_doc
    plan_doc=$(find_by_id "$TASK_ID" 2>/dev/null | grep -m1 "\-PLN\-" || true)

    if [[ -n "$plan_doc" ]] && [[ -f "$plan_doc" ]]; then
        local close_args=("--json" "--file" "$plan_doc" "--task-label" "Task Completed")
        [[ -n "$PROGRESS_SUMMARY" ]] && close_args+=("--progress" "$PROGRESS_SUMMARY")
        [[ -n "$WENT_WELL" ]] && close_args+=("--went-well" "$WENT_WELL")
        [[ -n "$CHALLENGES" ]] && close_args+=("--challenges" "$CHALLENGES")
        [[ -n "$DO_DIFFERENTLY" ]] && close_args+=("--differently" "$DO_DIFFERENTLY")
        [[ -n "$REUSABLE_PATTERNS" ]] && close_args+=("--patterns" "$REUSABLE_PATTERNS")
        "${SCRIPT_DIR}/plan-progress.sh" "${close_args[@]}" >/dev/null 2>&1 || true
        log "${GREEN}✓${NC} Wrote completion entry to PLN"
    fi

    # Extract accumulated progress/lessons from all PLN documents
    local lrn_filepath=""
    local lrn_template=""
    local lessons_json="[]"
    local lessons_count=0

    local all_pln_docs
    all_pln_docs=$(find_by_id "$TASK_ID" 2>/dev/null | grep "\-PLN\-" || true)

    if [[ -n "$all_pln_docs" ]]; then
        local combined="[]"
        while IFS= read -r pln_doc; do
            [[ -z "$pln_doc" ]] && continue
            local entries
            entries=$("${SCRIPT_DIR}/plan-progress.sh" --json --extract-entries --file "$pln_doc" 2>/dev/null || echo "[]")
            combined=$(echo "$combined $entries" | jq -s 'add')
        done <<< "$all_pln_docs"
        lessons_json="$combined"
        lessons_count=$(echo "$lessons_json" | jq 'length')
    fi

    # Only generate LRN doc if there are progress entries with content
    if [[ "$lessons_count" -gt 0 ]]; then
        local lrn_doc_json=""
        lrn_doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type LRN --description "lessons-learned" --id "$TASK_ID" --json 2>/dev/null || true)
        if [[ -n "$lrn_doc_json" ]]; then
            lrn_filepath=$(echo "$lrn_doc_json" | jq -r '.filepath // empty')
            lrn_template=$(echo "$lrn_doc_json" | jq -r '.template // empty')
        fi
        log "${GREEN}✓${NC} Found $lessons_count progress entries from PLN documents"
    fi

    # Collect ALL related documents (active + completed) for SUM generation
    local all_related_docs=""
    all_related_docs=$(find_by_id "$TASK_ID" 2>/dev/null || true)
    local related_docs_json="[]"
    if [[ -n "$all_related_docs" ]]; then
        related_docs_json=$(echo "$all_related_docs" | while IFS= read -r doc; do
            [[ -z "$doc" ]] && continue
            local fname=$(basename "$doc")
            local dtype=$(get_type "$fname" 2>/dev/null || echo "unknown")
            echo "{\"path\":\"$doc\",\"filename\":\"$fname\",\"type\":\"$dtype\"}"
        done | jq -s '.' 2>/dev/null || echo "[]")
    fi

    # Extract git log for the feature branch (for SUM context)
    local git_log=""
    git_log=$(git log --oneline --no-decorate -20 2>/dev/null | head -20 || echo "")
    local git_log_json
    git_log_json=$(echo "$git_log" | jq -Rs . 2>/dev/null || echo '""')

    # Detect PROJECT-KNOWLEDGE.md for accuracy review
    local project_knowledge_path=""
    local project_knowledge_diff=""
    for pk_candidate in "docs/architecture/PROJECT-KNOWLEDGE.md" "docs/PROJECT-KNOWLEDGE.md" "PROJECT-KNOWLEDGE.md"; do
        if [[ -f "$pk_candidate" ]]; then
            project_knowledge_path="$pk_candidate"
            break
        fi
    done
    if [[ -n "$project_knowledge_path" ]]; then
        # Collect the diff of code changes (not docs) so the AI can assess impact on PROJECT-KNOWLEDGE
        local merge_base
        merge_base=$(git merge-base "${DEFAULT_BRANCH}" HEAD 2>/dev/null || echo "")
        if [[ -n "$merge_base" ]]; then
            project_knowledge_diff=$(git diff "${merge_base}...HEAD" -- ':!docs/' ':!*.md' 2>/dev/null | head -500 || echo "")
        fi
        log "${BLUE}ℹ${NC} Found PROJECT-KNOWLEDGE.md — will review for accuracy"
    fi

    # If running only this section or as part of full workflow, return now
    if [[ "$SECTION" == "complete" || "$SECTION" == "full" ]]; then
        # Determine next_action based on what actually needs doing
        local _next_action="cleanup"
        local _status="ready_for_cleanup"
        local _message="Task completion data collected - no sync or generation needed, proceed to cleanup"
        if [[ "$SHOULD_SYNC_ASANA" == "true" ]] || [[ "$WORK_HOURS_LOGGED" == "true" ]]; then
            _next_action="sync_asana"
            _status="ready_for_sync"
            _message="Task completion data collected - ready for sync and summary generation"
        elif [[ -n "$sum_filepath" ]] || [[ $lessons_count -gt 0 ]]; then
            _next_action="generate_docs"
            _status="ready_for_docs"
            _message="Task completion data collected - ready for document generation"
        fi
        local json=$(cat <<EOF
{
  "status": "$_status",
  "next_action": "$_next_action",
  "section": "complete",
  "message": "$_message",
  "task_status": "completed",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_doc": "$TASK_DOC",
  "branch": "$CURRENT_BRANCH",
  "progress_summary": $(echo "$PROGRESS_SUMMARY" | jq -Rs .),
  "criteria_status": $(echo "$CRITERIA_STATUS" | jq -Rs .),
  "went_well": $(echo "$WENT_WELL" | jq -Rs .),
  "challenges": $(echo "$CHALLENGES" | jq -Rs .),
  "do_differently": $(echo "$DO_DIFFERENTLY" | jq -Rs .),
  "reusable_patterns": $(echo "$REUSABLE_PATTERNS" | jq -Rs .),
  "pr_number": "$PR_NUMBER",
  "pr_url": "$PR_URL",
  "pr_state": "$PR_STATE",
  "mr_number": "$MR_NUMBER",
  "asana_gid": "$ASANA_GID",
  "should_sync_asana": $SHOULD_SYNC_ASANA,
  "external_updated": $EXTERNAL_UPDATED,
  "work_hours_logged": $WORK_HOURS_LOGGED,
  "txtwire_hours": "$USER_HOURS",
  "txtwire_date": "$MOST_RECENT_DATE",
  "sum_filepath": $(printf '%s' "$sum_filepath" | jq -Rs .),
  "sum_template": $(echo "$sum_template" | jq -Rs .),
  "lrn_filepath": $(printf '%s' "$lrn_filepath" | jq -Rs .),
  "lrn_template": $(echo "$lrn_template" | jq -Rs .),
  "lessons": $lessons_json,
  "lessons_count": $lessons_count,
  "related_docs": $related_docs_json,
  "git_log": $git_log_json,
  "project_knowledge_path": $(printf '%s' "$project_knowledge_path" | jq -Rs .),
  "project_knowledge_diff": $(echo "$project_knowledge_diff" | jq -Rs .),
  "next_steps": [
    "LLM: Generate SUM document FIRST (read related_docs for context, lessons, patterns)",
    "LLM: If lessons_count > 0, generate LRN document",
    "LLM: If project_knowledge_path is non-empty, read it and review against project_knowledge_diff — update ONLY if inaccurate or missing info",
    "LLM: Update Asana status if configured",
    "LLM: Log work hours if TxtWire",
    "LLM: Commit SUM/LRN/PROJECT-KNOWLEDGE docs, then: task-close.sh --json --cleanup"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# ============================================================
# Section: task-close-defer
# ============================================================

# Sourced by task-close.sh — shares globals, no standalone execution


section_defer() {
    print_header "Task Deferral"

    if [[ "$AI_MODE" == "true" ]]; then
        # AI mode - use provided values
        DEFERRAL_REASON="${AI_DEFERRAL_REASON}"
        BLOCKER_DETAILS="${AI_BLOCKER}"
        EXPECTED_UNBLOCK_DATE="${AI_EXPECTED_DATE}"
        UNBLOCK_CONTACT="${AI_CONTACT}"
        WORK_DONE="${AI_ACCOMPLISHED}"  # Reuse accomplished field
        NEXT_STEPS="${AI_PATTERNS}"     # Or use a separate field if needed
    else
        # Interactive mode
        echo "Why is this task being deferred?" >&2
        echo "" >&2
        echo "Common reasons:" >&2
        echo "  - Blocked by another task/dependency" >&2
        echo "  - Reprioritized (lower priority now)" >&2
        echo "  - Scope changed (needs replanning)" >&2
        echo "  - Awaiting external input" >&2
        echo "  - Technical blocker discovered" >&2
        echo "" >&2
        read -p "Reason: " DEFERRAL_REASON >&2

        echo "" >&2
        echo "Blocker Details (optional, press Enter to skip)" >&2
        read -p "What is blocking this task? " BLOCKER_DETAILS >&2
        read -p "Expected unblock date (YYYY-MM-DD)? " EXPECTED_UNBLOCK_DATE >&2
        read -p "Who can unblock? " UNBLOCK_CONTACT >&2

        echo "" >&2
        read -p "Work completed so far? " WORK_DONE >&2
        read -p "Next steps when resumed? " NEXT_STEPS >&2
    fi

    # Update task document (if it exists in active/)
    if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]] && echo "$TASK_DOC" | grep -q "/active/"; then
        cat >> "$TASK_DOC" << EOF

---

## Task Deferred

**Status**: ⏸️  Deferred
**Deferred**: $(date -Iseconds)

### Deferral Reason
${DEFERRAL_REASON}

### Blocker Details
- **What**: ${BLOCKER_DETAILS:-N/A}
- **Expected unblock**: ${EXPECTED_UNBLOCK_DATE:-Unknown}
- **Who can unblock**: ${UNBLOCK_CONTACT:-N/A}

### Work Completed So Far
${WORK_DONE:-None}

### Next Steps When Resumed
${NEXT_STEPS:-TBD}

---
EOF

        git add "$TASK_DOC" 2>/dev/null || true
        log "${GREEN}✓${NC} Task document updated with deferral"
    else
        log "${BLUE}ℹ${NC} No active task document to update"
    fi
    log "${GREEN}✓${NC} Task document updated with deferral details"

    # Update external systems
    if [[ -n "$ISSUE_NUMBER" ]] && [[ "$GIT_PLATFORM" == "github" ]]; then
        if command -v gh &> /dev/null; then
            local issue_num=$(echo "$ISSUE_NUMBER" | tr -d '#')
            gh issue comment "$issue_num" --body "⏸️ Task deferred: $DEFERRAL_REASON" 2>/dev/null && \
                EXTERNAL_UPDATED=true && \
                log "${GREEN}✓${NC} Updated GitHub issue #$issue_num" || \
                log "${YELLOW}⚠${NC} Could not update GitHub issue"
        fi
    fi

    # Check Asana integration
    if [[ -f "PROJECT.yaml" ]]; then
        local backend=$(yaml_get '.task_management.backend' PROJECT.yaml)
        local sync_on_close=$(yaml_get '.task_management.asana.sync_on_operations[] | select(. == "close")' PROJECT.yaml)

        if [[ "$backend" == "asana" ]] && [[ -n "$sync_on_close" ]] && [[ -n "$ASANA_GID" ]]; then
            SHOULD_SYNC_ASANA=true
            log "${BLUE}ℹ${NC} Asana sync required (will be handled by LLM)"
        fi
    fi

    log "${GREEN}✓${NC} Deferred task processing"

    # If running only this section or as part of full workflow, return now
    if [[ "$SECTION" == "defer" || "$SECTION" == "full" ]]; then
        # Determine next_action based on what actually needs doing
        local _next_action="cleanup"
        local _status="ready_for_cleanup"
        local _message="Task deferral data collected - no sync needed, proceed to cleanup"
        if [[ "$SHOULD_SYNC_ASANA" == "true" ]]; then
            _next_action="sync_asana"
            _status="ready_for_sync"
            _message="Task deferral data collected - ready for sync"
        fi
        local json=$(cat <<EOF
{
  "status": "$_status",
  "next_action": "$_next_action",
  "section": "defer",
  "message": "$_message",
  "task_status": "deferred",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_doc": "$TASK_DOC",
  "branch": "$CURRENT_BRANCH",
  "deferral_reason": $(echo "$DEFERRAL_REASON" | jq -Rs .),
  "blocker_details": $(echo "$BLOCKER_DETAILS" | jq -Rs .),
  "expected_unblock_date": "$EXPECTED_UNBLOCK_DATE",
  "unblock_contact": "$UNBLOCK_CONTACT",
  "work_done": $(echo "$WORK_DONE" | jq -Rs .),
  "user_next_steps": $(echo "$NEXT_STEPS" | jq -Rs .),
  "asana_gid": "$ASANA_GID",
  "should_sync_asana": $SHOULD_SYNC_ASANA,
  "external_updated": $EXTERNAL_UPDATED,
  "next_steps": [
    "LLM: Update Asana status if configured",
    "Then: task-close.sh --json --cleanup"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# ============================================================
# Section: task-close-sync
# ============================================================

# Sourced by task-close.sh — shares globals, no standalone execution


section_extract_summary_data() {
    print_header "Extract Summary Data"

    # Use single efficient pass to extract first + last 3 summaries (not all 12)
    # This avoids the performance issue with processing too many summaries
    local summaries_data=$(awk '
        /^## Completion Summary/ {
            if (in_summary && summary_idx > 0) {
                # Store previous summary before starting new one
                if (summary_idx == 1 || summary_idx > (total_summaries - 3)) {
                    completed[summary_idx] = current_completed
                    accomplished[summary_idx] = current_accomplished
                    went_well[summary_idx] = current_went_well
                    challenges[summary_idx] = current_challenges
                    patterns[summary_idx] = current_patterns
                }
            }
            summary_idx++
            in_summary = 1
            current_section = ""
            current_completed = ""
            current_accomplished = ""
            current_went_well = ""
            current_challenges = ""
            current_patterns = ""
            next
        }
        /^\*\*Completed\*\*:/ && in_summary {
            sub(/^\*\*Completed\*\*: */, "")
            current_completed = $0
            next
        }
        /^### What Was Accomplished/ && in_summary {
            current_section = "accomplished"
            next
        }
        /^### What Went Well/ && in_summary {
            current_section = "went_well"
            next
        }
        /^### Challenges/ && in_summary {
            current_section = "challenges"
            next
        }
        /^### Reusable Patterns/ && in_summary {
            current_section = "patterns"
            next
        }
        /^###/ && in_summary {
            current_section = ""
            next
        }
        /^---$/ && in_summary {
            # End of summary section
            if (summary_idx == 1 || summary_idx > (total_summaries - 3)) {
                completed[summary_idx] = current_completed
                accomplished[summary_idx] = current_accomplished
                went_well[summary_idx] = current_went_well
                challenges[summary_idx] = current_challenges
                patterns[summary_idx] = current_patterns
            }
            in_summary = 0
            next
        }
        in_summary && current_section != "" && NF > 0 {
            line = $0
            # Skip blank lines and heading markers
            if (line !~ /^$/ && line !~ /^###/ && line !~ /^\*\*/) {
                if (current_section == "accomplished") {
                    current_accomplished = current_accomplished (current_accomplished ? " " : "") line
                } else if (current_section == "went_well") {
                    current_went_well = current_went_well (current_went_well ? " " : "") line
                } else if (current_section == "challenges") {
                    current_challenges = current_challenges (current_challenges ? " " : "") line
                } else if (current_section == "patterns") {
                    current_patterns = current_patterns (current_patterns ? " " : "") line
                }
            }
        }
        END {
            # Store last summary if needed
            if (in_summary && (summary_idx == 1 || summary_idx > (total_summaries - 3))) {
                completed[summary_idx] = current_completed
                accomplished[summary_idx] = current_accomplished
                went_well[summary_idx] = current_went_well
                challenges[summary_idx] = current_challenges
                patterns[summary_idx] = current_patterns
            }
            total_summaries = summary_idx
            # Count how many we want (first + last 3)
            count = 0
            for (idx = 1; idx <= total_summaries; idx++) {
                if (idx == 1 || idx > total_summaries - 3) {
                    if (count > 0) print "|||"
                    print "COMPLETED=" completed[idx]
                    print "ACCOMPLISHED=" accomplished[idx]
                    print "WENT_WELL=" went_well[idx]
                    print "CHALLENGES=" challenges[idx]
                    print "PATTERNS=" patterns[idx]
                    count++
                }
            }
        }
    ' "$TASK_DOC")

    # Convert to JSON efficiently
    local summaries_json="["
    local first=true
    while IFS= read -r line; do
        if [[ "$line" == "|||" ]]; then
            [[ "$first" == "false" ]] && summaries_json+=","
            summaries_json+=$(printf '{"completed":%s,"accomplished":%s,"went_well":%s,"challenges":%s,"patterns":%s}' \
                "$(echo "$COMPLETED" | jq -Rs .)" \
                "$(echo "$ACCOMPLISHED" | jq -Rs .)" \
                "$(echo "$WENT_WELL" | jq -Rs .)" \
                "$(echo "$CHALLENGES" | jq -Rs .)" \
                "$(echo "$PATTERNS" | jq -Rs .)")
            first=false
            COMPLETED="" ACCOMPLISHED="" WENT_WELL="" CHALLENGES="" PATTERNS=""
        elif [[ "$line" =~ ^COMPLETED= ]]; then
            COMPLETED="${line#COMPLETED=}"
        elif [[ "$line" =~ ^ACCOMPLISHED= ]]; then
            ACCOMPLISHED="${line#ACCOMPLISHED=}"
        elif [[ "$line" =~ ^WENT_WELL= ]]; then
            WENT_WELL="${line#WENT_WELL=}"
        elif [[ "$line" =~ ^CHALLENGES= ]]; then
            CHALLENGES="${line#CHALLENGES=}"
        elif [[ "$line" =~ ^PATTERNS= ]]; then
            PATTERNS="${line#PATTERNS=}"
        fi
    done <<< "$summaries_data"

    # Add last summary if exists
    if [[ -n "$COMPLETED" ]]; then
        [[ "$first" == "false" ]] && summaries_json+=","
        summaries_json+=$(printf '{"completed":%s,"accomplished":%s,"went_well":%s,"challenges":%s,"patterns":%s}' \
            "$(echo "$COMPLETED" | jq -Rs .)" \
            "$(echo "$ACCOMPLISHED" | jq -Rs .)" \
            "$(echo "$WENT_WELL" | jq -Rs .)" \
            "$(echo "$CHALLENGES" | jq -Rs .)" \
            "$(echo "$PATTERNS" | jq -Rs .)")
    fi
    summaries_json+="]"

    # Rest of extraction (git, docs) - keep as is but optimize
    local git_log=$(git log --oneline --grep="Refs #${TASK_ID}" -20 2>/dev/null || echo "")
    local commit_count=$(echo "$git_log" | wc -l)
    local git_stats=$(git diff --stat "$DEFAULT_BRANCH..$CURRENT_BRANCH" 2>/dev/null | tail -1 || echo "N/A")
    local files_changed=$(git diff --name-only "$DEFAULT_BRANCH..$CURRENT_BRANCH" 2>/dev/null | wc -l)

    # Optimize document listing - single find, multiple greps
    local all_docs=$(find_by_id "$TASK_ID" | grep -E "\.(md|txt)$" || true)
    local docs_json=$(printf '{"tsk":%s,"pln":%s,"vrf":%s,"aud":%s,"rsk":%s,"inc":%s}' \
        "$(echo "$all_docs" | grep "TSK-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "PLN-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "VRF-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "AUD-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "RSK-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "INC-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')")

    log "${GREEN}✓${NC} Extracted data (first + last 3 summaries, $(echo "$summaries_json" | jq '. | length') total)"

    # Return comprehensive data
    local json=$(printf '{"status":"needs_llm","next_action":"parse_content","section":"extract-summary-data","message":"Raw data extracted - needs AI synthesis","task_id":"%s","task_title":%s,"completion_summaries":%s,"git_log":%s,"commit_count":%d,"git_stats":%s,"files_changed":%d,"related_documents":%s,"pr_url":"%s","pr_state":"%s","branch":"%s","next_steps":["LLM: Read all completion_summaries and git data","LLM: Synthesize comprehensive narrative","LLM: Call --create-summary with synthesized content"],"timestamp":"%s"}' \
        "$TASK_ID" \
        "$(echo "$TASK_TITLE" | jq -Rs .)" \
        "$summaries_json" \
        "$(echo "$git_log" | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$commit_count" \
        "$(echo "$git_stats" | jq -Rs .)" \
        "$files_changed" \
        "$docs_json" \
        "$PR_URL" \
        "$PR_STATE" \
        "$CURRENT_BRANCH" \
        "$(date -Iseconds)")

    log_json "$json"
    exit 0
}

section_create_summary() {
    print_header "Create Summary Document"

    # Use AI-provided content or extract from flags
    local summary_title="${AI_SUMMARY_TITLE:-$TASK_TITLE}"
    local summary_overview="${AI_SUMMARY_OVERVIEW}"
    local summary_accomplishments="${AI_SUMMARY_ACCOMPLISHMENTS}"
    local summary_key_outcomes="${AI_SUMMARY_KEY_OUTCOMES}"
    local summary_patterns="${AI_SUMMARY_PATTERNS}"
    local completion_timestamp="${AI_SUMMARY_TIMESTAMP:-$(date -Iseconds)}"
    local datetime=$(echo "$completion_timestamp" | sed 's/[:-]//g;s/T//;s/\+.*//;s/\(........\).*/\1/')

    # Extract task slug from TSK document filename
    local tsk_filename=$(basename "$TASK_DOC")
    TASK_SLUG=$(echo "$tsk_filename" | sed -E 's/^[0-9]{4}-[0-9]{10}-TSK-//' | sed 's/.md$//')

    SUMMARY_FILENAME="${TASK_ID}-${datetime}-SUM-${TASK_SLUG}.md"
    local summary_path="${DOCS_DIR}/completed/${RANGE_FOLDER}/${SUMMARY_FILENAME}"

    # Ensure completed range folder exists
    mkdir -p "${DOCS_DIR}/completed/${RANGE_FOLDER}"

    # Get related documents for listing
    local all_docs=$(find_by_id "$TASK_ID" | grep -E "\.(md|txt)$" || true)
    local tsk_list=$(echo "$all_docs" | grep "TSK-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local pln_list=$(echo "$all_docs" | grep "PLN-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local vrf_list=$(echo "$all_docs" | grep "VRF-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local aud_list=$(echo "$all_docs" | grep "AUD-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local rsk_list=$(echo "$all_docs" | grep "RSK-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local inc_list=$(echo "$all_docs" | grep "INC-" | sed 's#.*/##' | sed 's/^/- /' || true)

    # Create summary document
    cat > "$summary_path" << EOF
# Summary: ${summary_title}

**Task ID**: $TASK_ID
**Type**: Summary (SUM)
**Status**: ✓ Completed
**Date**: $completion_timestamp

---

## Overview

${summary_overview}

---

## What Was Accomplished

${summary_accomplishments}

---

## Key Outcomes

${summary_key_outcomes}

---

## Reusable Patterns

${summary_patterns}

---

## Related Documents

**Task Documents**:
${tsk_list:-None}

**Planning & Analysis**:
${pln_list:-None}

**Verification & Testing**:
${vrf_list:-None}

**Audits & Reviews**:
${aud_list:-None}

**Risk Analysis**:
${rsk_list:-None}

$(if [[ -n "$inc_list" ]]; then echo "**Incidents**:"; echo "$inc_list"; fi)
$(if [[ -n "$PR_URL" ]]; then echo "**PR/MR**: $PR_URL"; fi)

---

**Completed**: $completion_timestamp
**Status**: ✓ Completed
EOF

    git add "$summary_path"
    log "${GREEN}✓${NC} Summary document created: $SUMMARY_FILENAME"

    # Return success
    local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "create-summary",
  "message": "Summary document created",
  "summary_filename": "$SUMMARY_FILENAME",
  "summary_path": "$summary_path",
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    exit 0
}

# ============================================================
# Section: task-close-cleanup
# ============================================================

# Sourced by task-close.sh — shares globals, no standalone execution


# Resolve merge target non-interactively. Writes lockfile on success.
# Sets: RESOLVED_TARGET_BRANCH, RESOLVED_FEATURE_BRANCH
# Returns: 0 on success, 1 on ambiguity/error (caller should exit_with_json).
# Emits errors via exit_with_json directly for unrecoverable cases.
resolve_merge_target() {
    RESOLVED_TARGET_BRANCH=""
    RESOLVED_FEATURE_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"

    # Priority 1: Lockfile from a previous run
    if read_close_state; then
        RESOLVED_TARGET_BRANCH="$LOCKED_TARGET_BRANCH"
        RESOLVED_FEATURE_BRANCH="$LOCKED_FEATURE_BRANCH"
        return 0
    fi

    # Priority 2: Explicit --target-branch flag
    if [[ -n "${MERGE_TARGET:-}" ]]; then
        RESOLVED_TARGET_BRANCH="$MERGE_TARGET"

    # Priority 3: parent_branch from .current-task JSON
    elif load_current_task && [[ -n "${CT_PARENT_BRANCH:-}" ]]; then
        RESOLVED_TARGET_BRANCH="$CT_PARENT_BRANCH"
        [[ -n "${CT_BRANCH:-}" ]] && RESOLVED_FEATURE_BRANCH="$CT_BRANCH"

    # Priority 4: Auto-detect (caller decides whether to confirm)
    else
        local detected=""
        if detected=$(detect_source_branch 2>/dev/null); then
            if [[ "$AI_MODE" == "true" ]]; then
                exit_with_json "needs_decision" \
                    "Merge target auto-detected as '$detected'. No parent_branch in .current-task." \
                    "Confirm target branch or override with --target-branch" \
                    "\"reason\": \"confirm_merge_target\"," \
                    "\"detected_target\": \"$detected\"," \
                    "\"feature_branch\": \"$RESOLVED_FEATURE_BRANCH\"," \
                    "\"task_id\": \"$TASK_ID\""
            else
                echo ""
                echo "  Merge target detected: $detected"
                echo "  Feature branch: $RESOLVED_FEATURE_BRANCH"
                echo ""
                read -r -p "  Merge into '$detected'? [y/N/branch]: " confirm
                case "$confirm" in
                    y|Y|yes|YES) RESOLVED_TARGET_BRANCH="$detected" ;;
                    ""|n|N|no|NO)
                        echo "Aborted. Use --target-branch <branch> to specify manually."
                        exit 1 ;;
                    *)
                        if git rev-parse --verify "$confirm" &>/dev/null; then
                            RESOLVED_TARGET_BRANCH="$confirm"
                        else
                            echo "Error: Branch '$confirm' does not exist."
                            exit 1
                        fi ;;
                esac
            fi
        else
            if [[ "$RESOLVED_FEATURE_BRANCH" == "$DEFAULT_BRANCH" ]]; then
                RESOLVED_TARGET_BRANCH="$DEFAULT_BRANCH"
            else
                exit_with_json "error" "Could not detect parent branch and no parent_branch in .current-task" \
                    "Use --target-branch <branch> to specify manually, or run task-recover.sh first" \
                    "\"current_branch\": \"$RESOLVED_FEATURE_BRANCH\""
            fi
        fi
    fi

    # Validate: feature branch must not be a protected branch
    if is_protected_branch "$RESOLVED_FEATURE_BRANCH"; then
        exit_with_json "error" "Refusing to close protected branch '$RESOLVED_FEATURE_BRANCH'" \
            "Protected branches cannot be closed with task-close. Check ci.branches in PROJECT.yaml." \
            "\"feature_branch\": \"$RESOLVED_FEATURE_BRANCH\""
    fi

    # Write lockfile
    if [[ -n "$RESOLVED_TARGET_BRANCH" ]] && [[ -n "$RESOLVED_FEATURE_BRANCH" ]]; then
        write_close_state "$TASK_ID" "$RESOLVED_FEATURE_BRANCH" "$RESOLVED_TARGET_BRANCH"
    fi

    return 0
}

# Run pre-merge verification (rebase/lint/test/build).
# Args: $1 = target_branch
# Returns: 0 on pass/skipped, 1 on fail (emits exit_with_json on fail).
# On success, records verified_sha in lockfile so --cleanup can skip re-running.
run_pre_merge_verify() {
    local target_branch="$1"

    if [[ ! -f "${SCRIPT_DIR}/pre-merge-verify.sh" ]]; then
        log "${YELLOW}⚠${NC} pre-merge-verify.sh not found — skipping"
        return 0
    fi

    log "${BLUE}ℹ${NC} Running pre-merge verification against '$target_branch'..."
    local verify_result verify_exit
    verify_result=$("${SCRIPT_DIR}/pre-merge-verify.sh" --json --target-branch "$target_branch" 2>/dev/null) && verify_exit=0 || verify_exit=$?
    local verify_status
    verify_status=$(echo "$verify_result" | jq -r '.status // empty' 2>/dev/null || echo "")

    if [[ "$verify_status" == "pass" ]] || [[ "$verify_status" == "skipped" ]]; then
        local head_sha
        head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        [[ -n "$head_sha" ]] && write_close_verified "$head_sha"
        if [[ "$verify_status" == "pass" ]]; then
            log "${GREEN}✓${NC} Pre-merge verification passed (recorded at ${head_sha:0:7})"
        else
            local skip_reason
            skip_reason=$(echo "$verify_result" | jq -r '.skipped_reason // "doc-only changes"' 2>/dev/null || echo "doc-only changes")
            log "${BLUE}ℹ${NC} Pre-merge verification skipped ($skip_reason)"
        fi
        return 0
    elif [[ "$verify_status" == "fail" ]]; then
        log "${RED}✗${NC} Pre-merge verification failed"
        while IFS= read -r step_json; do
            local sname sdetail
            sname=$(echo "$step_json" | jq -r '.name // empty' 2>/dev/null || true)
            sdetail=$(echo "$step_json" | jq -r '.detail // empty' 2>/dev/null || true)
            [[ -n "$sname" ]] && log "  Failed step: $sname${sdetail:+ — $sdetail}"
        done < <(echo "$verify_result" | jq -c '.steps[] | select(.status == "fail")' 2>/dev/null || true)
        exit_with_json "error" "Pre-merge verification failed — fix the issues and re-run /task-close" "$verify_result"
    elif [[ $verify_exit -ne 0 ]]; then
        log "${RED}✗${NC} Pre-merge verification script crashed (exit $verify_exit)"
        exit_with_json "error" "Pre-merge verification script crashed (exit $verify_exit)" "${verify_result:-no output}"
    else
        log "${BLUE}ℹ${NC} Pre-merge verification returned unknown status: ${verify_status:-empty}"
        return 0
    fi
}

# --pre-verify section: run merge verification early, before any doc generation.
# This catches rebase/lint/test/build failures BEFORE the LLM spends time writing
# SUM/LRN docs that would otherwise be stranded on a branch that won't merge.
section_pre_verify() {
    print_header "Pre-Merge Verification"

    # Deferred tasks never merge, so skip.
    if [[ "$STATUS" != "completed" ]] || [[ "$MERGE_BRANCH" != "true" ]]; then
        log "${BLUE}ℹ${NC} Skipping pre-verify (task is not being merged)"
        if [[ "$SECTION" == "pre-verify" ]]; then
            exit_with_json "success" "Pre-verify skipped — task will not be merged" "" \
                '"verified": false, "reason": "no_merge"'
        fi
        return 0
    fi

    resolve_merge_target

    if [[ -z "$RESOLVED_TARGET_BRANCH" ]]; then
        exit_with_json "error" "Could not resolve merge target for pre-verification" \
            "Provide --target-branch or run from a branch with a known parent"
    fi

    run_pre_merge_verify "$RESOLVED_TARGET_BRANCH"

    if [[ "$SECTION" == "pre-verify" ]]; then
        local head_sha
        head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        exit_with_json "verified" "Pre-merge verification passed — safe to generate docs" \
            "Proceed with SUM/LRN generation, then call --cleanup to finalize" \
            "\"verified\": true," \
            "\"verified_sha\": \"$head_sha\"," \
            "\"target_branch\": \"$RESOLVED_TARGET_BRANCH\"," \
            "\"feature_branch\": \"$RESOLVED_FEATURE_BRANCH\""
    fi
}

section_cleanup() {
    print_header "Cleanup"

    # Use the ACTUAL current git branch — not .current-task contents
    CURRENT_BRANCH=$(git branch --show-current)

    # Extract task slug from TSK document filename
    local tsk_filename=$(basename "$TASK_DOC")
    TASK_SLUG=$(echo "$tsk_filename" | sed -E 's/^[A-Fa-f0-9]{6}-[0-9]{10}-TSK-//' | sed 's/.md$//')

    # Extract completion data from task document
    # Extract completion data from task document (if it exists)
    if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]]; then
        local last_summary_start=$(grep -n "^## Completion Summary" "$TASK_DOC" | tail -1 | cut -d: -f1)

        if [[ -n "$last_summary_start" ]]; then
            local completion_section=$(tail -n +$last_summary_start "$TASK_DOC" | sed -n '1,/^---$/p' | sed '$d')

            PROGRESS_SUMMARY=$(echo "$completion_section" | awk '/^### What Was Accomplished$/{flag=1;next}/^###/{flag=0}flag' | sed '/^$/d')
            WENT_WELL=$(echo "$completion_section" | awk '/^### What Went Well$/{flag=1;next}/^###/{flag=0}flag' | sed '/^$/d')
            CHALLENGES=$(echo "$completion_section" | awk '/^### Challenges$/{flag=1;next}/^###/{flag=0}flag' | sed '/^$/d')
            DO_DIFFERENTLY=$(echo "$completion_section" | awk '/^### What Would You Do Differently$/{flag=1;next}/^###/{flag=0}flag' | sed '/^$/d')
            REUSABLE_PATTERNS=$(echo "$completion_section" | awk '/^### Reusable Patterns$/{flag=1;next}/^###/{flag=0}flag' | sed '/^$/d')

            if echo "$completion_section" | grep -q "Status.*Completed"; then
                STATUS="completed"
            elif echo "$completion_section" | grep -q "Status.*Deferred"; then
                STATUS="deferred"
            fi

            log "${GREEN}✓${NC} Extracted completion data from task document"
        fi
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 1: Resolve merge target (lockfile → .current-task → detect + confirm)
    # Uses lockfile to prevent cascade merges on retry.
    # ──────────────────────────────────────────────────────────────────

    local target_branch=""
    local feature_branch="$CURRENT_BRANCH"

    if [[ "$STATUS" == "completed" ]] && [[ "$MERGE_BRANCH" == "true" ]]; then

        # Priority 1: Lockfile from a previous run (prevents cascade on retry)
        if read_close_state; then
            target_branch="$LOCKED_TARGET_BRANCH"
            feature_branch="$LOCKED_FEATURE_BRANCH"
            log "${BLUE}ℹ${NC} Using locked target from .task-close-state: $feature_branch → $target_branch"

        # Priority 2: Explicit --target-branch flag
        elif [[ -n "$MERGE_TARGET" ]]; then
            target_branch="$MERGE_TARGET"
            log "${BLUE}ℹ${NC} Using explicit target: $target_branch"

        # Priority 3: parent_branch from .current-task JSON
        elif load_current_task && [[ -n "$CT_PARENT_BRANCH" ]]; then
            target_branch="$CT_PARENT_BRANCH"
            feature_branch="$CT_BRANCH"
            log "${BLUE}ℹ${NC} Using parent_branch from .current-task: $target_branch"

        # Priority 4: Auto-detect with user confirmation
        else
            local detected=""
            if detected=$(detect_source_branch 2>/dev/null); then
                if [[ "$AI_MODE" == "true" ]]; then
                    # AI mode: return needs_decision for LLM to confirm
                    exit_with_json "needs_decision" \
                        "Merge target auto-detected as '$detected'. No parent_branch in .current-task." \
                        "Confirm target branch or override with --target-branch" \
                        "\"reason\": \"confirm_merge_target\"," \
                        "\"detected_target\": \"$detected\"," \
                        "\"feature_branch\": \"$CURRENT_BRANCH\"," \
                        "\"task_id\": \"$TASK_ID\"," \
                        "\"next_steps\": [\"Confirm: task-close.sh --json --ai --cleanup --target-branch $detected --task-id $TASK_ID\", \"Override: task-close.sh --json --ai --cleanup --target-branch <other> --task-id $TASK_ID\"]"
                else
                    # Interactive mode: prompt user
                    echo ""
                    echo "  Merge target detected: $detected"
                    echo "  Feature branch: $CURRENT_BRANCH"
                    echo ""
                    read -r -p "  Merge into '$detected'? [y/N/branch]: " confirm
                    case "$confirm" in
                        y|Y|yes|YES)
                            target_branch="$detected"
                            ;;
                        ""|n|N|no|NO)
                            echo "Aborted. Use --target-branch <branch> to specify manually."
                            exit 1
                            ;;
                        *)
                            # User provided a branch name
                            if git rev-parse --verify "$confirm" &>/dev/null; then
                                target_branch="$confirm"
                            else
                                echo "Error: Branch '$confirm' does not exist."
                                exit 1
                            fi
                            ;;
                    esac
                fi
            else
                if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
                    log "${BLUE}ℹ${NC} Already on $DEFAULT_BRANCH — merge already completed"
                    target_branch="$DEFAULT_BRANCH"
                else
                    exit_with_json "error" "Could not detect parent branch and no parent_branch in .current-task" \
                        "Use --target-branch <branch> to specify manually, or run task-recover.sh first" \
                        "\"current_branch\": \"$CURRENT_BRANCH\""
                fi
            fi
        fi

        # Validate: feature branch must not be a protected branch
        if is_protected_branch "$feature_branch"; then
            exit_with_json "error" "Refusing to close protected branch '$feature_branch'" \
                "Protected branches cannot be closed with task-close. Check ci.branches in PROJECT.yaml." \
                "\"feature_branch\": \"$feature_branch\""
        fi

        # Write lockfile (idempotent — overwrites if exists)
        if [[ -n "$target_branch" ]] && [[ -n "$feature_branch" ]]; then
            write_close_state "$TASK_ID" "$feature_branch" "$target_branch"
            write_close_checkpoint "target_resolved"
            log "${GREEN}✓${NC} Locked merge target: $feature_branch → $target_branch"
        fi

        MERGE_TARGET="$target_branch"
        log "${BLUE}ℹ${NC} Parent branch: $target_branch"
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 2: Require clean working tree
    # ──────────────────────────────────────────────────────────────────

    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        local dirty_files
        dirty_files=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
        dirty_files=$(echo "$dirty_files" | sort -u | head -5 | tr '\n' ', ')
        exit_with_json "error" \
            "Uncommitted changes — commit all changes before closing: ${dirty_files}" \
            "Run /git-commit first, then re-run /task-close"
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 2.5: Remove worktree before merge (DSN Decision 6)
    # ──────────────────────────────────────────────────────────────────
    # In worktree mode, we must remove the worktree BEFORE merging because
    # you can't delete a branch that's checked out in a worktree. The flow is:
    # detect worktree → cd to main checkout → remove worktree → normal merge.

    if [[ "$STATUS" == "completed" ]] && [[ "$MERGE_BRANCH" == "true" ]]; then
        if declare -f is_in_worktree &>/dev/null && is_in_worktree; then
            if ! has_close_checkpoint "worktree_removed"; then
                local main_root
                main_root=$(get_main_checkout 2>/dev/null || echo "")
                if [[ -n "$main_root" ]] && [[ -d "$main_root" ]]; then
                    log "${BLUE}ℹ${NC} Worktree mode detected — switching to main checkout"
                    cd "$main_root" || exit_with_json "error" "Failed to cd to main checkout: $main_root"
                    remove_task_worktree "$TASK_ID"
                    write_close_checkpoint "worktree_removed"
                    log "${GREEN}✓${NC} Worktree removed, now in main checkout: $main_root"
                fi
            else
                log "${GREEN}✓${NC} Worktree removal already checkpointed — skipping"
            fi
        elif declare -f get_main_checkout &>/dev/null; then
            # Not in a worktree but check if one exists for this task (cleanup from prior run)
            local wt_path
            wt_path=$(get_worktree_path "$TASK_ID" 2>/dev/null || echo "")
            if [[ -n "$wt_path" ]] && [[ -d "$wt_path" ]] && ! has_close_checkpoint "worktree_removed"; then
                remove_task_worktree "$TASK_ID"
                write_close_checkpoint "worktree_removed"
                log "${GREEN}✓${NC} Cleaned up orphaned worktree: $wt_path"
            fi
        fi
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 3: Squash merge into parent branch (completed tasks only)
    # ──────────────────────────────────────────────────────────────────

    local MERGED=false
    # feature_branch resolved in Step 1 from lockfile/.current-task
    # For deferred tasks (no merge), fall back to CURRENT_BRANCH
    [[ -z "$feature_branch" ]] && feature_branch="$CURRENT_BRANCH"

    if [[ "$STATUS" == "completed" ]] && [[ "$MERGE_BRANCH" == "true" ]]; then

        # Checkpoint: a previous run already completed the merge — skip.
        if has_close_checkpoint "merged"; then
            log "${GREEN}✓${NC} Merge checkpoint already recorded — skipping merge step"
            MERGED=true

        # Already on target — merge already done (idempotent)
        elif [[ "$CURRENT_BRANCH" == "$target_branch" ]]; then
            log "${BLUE}ℹ${NC} Already on $target_branch, skipping merge"
            MERGED=true
            write_close_checkpoint "merged"

        # PR already merged — just clean up
        elif [[ "$PR_STATE" == "merged" || "$PR_STATE" == "MERGED" ]]; then
            log "${BLUE}ℹ${NC} PR already merged, skipping squash merge"
            MERGED=true
            write_close_checkpoint "merged"

        # Source branch gone — already merged in a previous run
        elif ! git rev-parse --verify "$CURRENT_BRANCH" &>/dev/null; then
            log "${BLUE}ℹ${NC} Branch $CURRENT_BRANCH no longer exists (already merged?)"
            MERGED=true
            write_close_checkpoint "merged"

        else
            log "${BLUE}ℹ${NC} Squash merging $CURRENT_BRANCH → $target_branch"
            git fetch origin "$target_branch" >/dev/null 2>&1 || true

            # Pre-merge verification per Branch, Merge & Deploy SOP
            # Rebase, lint affected services, test affected services, build all
            #
            # Skip if already passed for the current HEAD via `--pre-verify`. This lets
            # /task-close run verification BEFORE doc generation (fail fast, no stranded
            # doc commits) and reuse the result here without paying the cost twice.
            local current_head
            current_head=$(git rev-parse HEAD 2>/dev/null || echo "")
            if [[ -n "${LOCKED_VERIFIED_SHA:-}" ]] && [[ -n "$current_head" ]] && [[ "$LOCKED_VERIFIED_SHA" == "$current_head" ]]; then
                log "${GREEN}✓${NC} Pre-merge verification already passed at ${current_head:0:7} (skipping)"
            else
                run_pre_merge_verify "$target_branch"
            fi

            # Build a descriptive commit message using conventional commits.
            local merge_msg
            merge_msg=$(cat <<MERGEMSG
feat(${TASK_SLUG%%[-_]*}): ${TASK_TITLE}

${PROGRESS_SUMMARY:-Completed task ${TASK_ID}.}

$(if [[ -n "$WENT_WELL" ]]; then echo "What went well:"; echo "$WENT_WELL"; echo ""; fi)\
$(if [[ -n "$CHALLENGES" ]]; then echo "Challenges:"; echo "$CHALLENGES"; echo ""; fi)\
$(if [[ -n "$REUSABLE_PATTERNS" ]]; then echo "Patterns:"; echo "$REUSABLE_PATTERNS"; echo ""; fi)\
Work-Item: ${TASK_ID}
MERGEMSG
)

            local merge_result
            if merge_result=$("${SCRIPT_DIR}/git-merge.sh" --json --full --squash \
                --message "$merge_msg" \
                --source "$feature_branch" --target "$target_branch"); then

                local merge_status
                merge_status=$(echo "$merge_result" | jq -r '.status // empty' 2>/dev/null || echo "")
                local merge_hash
                merge_hash=$(echo "$merge_result" | jq -r '.merge_hash // empty' 2>/dev/null || echo "")

                if [[ "$merge_status" == "success" ]] && [[ -n "$merge_hash" ]]; then
                    MERGED=true
                    write_close_checkpoint "merged"
                    log "${GREEN}✓${NC} Squash merged to $target_branch (${merge_hash:0:7})"
                else
                    log "${YELLOW}⚠${NC} git-merge.sh returned status=$merge_status without completing merge"
                    exit_with_json "error" "Merge did not complete (status: $merge_status)" \
                        "git-merge.sh returned exit 0 but merge was not executed" \
                        "\"merge_response\": $(echo "$merge_result" | jq -Rs . 2>/dev/null || echo '\"\"'), \"source_branch\": \"$feature_branch\", \"target_branch\": \"$target_branch\""
                fi
            else
                local merge_status
                merge_status=$(echo "$merge_result" | jq -r '.status // empty' 2>/dev/null || echo "")
                if [[ "$merge_status" == "conflict" ]]; then
                    local conflict_files
                    conflict_files=$(echo "$merge_result" | jq -r '.conflict_files // []' 2>/dev/null)
                    exit_with_json "conflict" \
                        "Merge conflict: $feature_branch → $target_branch" \
                        "Resolve conflicts then resume with: task-close.sh --json --cleanup --task-id $TASK_ID" \
                        "\"conflict_files\": $conflict_files, \"source_branch\": \"$feature_branch\", \"target_branch\": \"$target_branch\""
                else
                    local err_msg
                    err_msg=$(echo "$merge_result" | jq -r '.message // "Unknown merge error"' 2>/dev/null)
                    if echo "$err_msg" | grep -qi "no commits"; then
                        log "${BLUE}ℹ${NC} No commits to merge — target already up to date"
                        MERGED=true
                        write_close_checkpoint "merged"
                    else
                        exit_with_json "error" "Merge failed: $err_msg" \
                            "Use --no-merge to skip, or fix and retry" \
                            "\"source_branch\": \"$feature_branch\", \"target_branch\": \"$target_branch\""
                    fi
                fi
            fi
        fi

    elif [[ "$STATUS" == "completed" ]] && [[ "$MERGE_BRANCH" == "false" ]]; then
        log "${BLUE}ℹ${NC} Skipping merge (--no-merge)"
    fi
    # Deferred tasks: no merge, no branch deletion

    # ──────────────────────────────────────────────────────────────────
    # Step 4: Switch to parent branch (completed tasks)
    # ──────────────────────────────────────────────────────────────────

    if [[ "$STATUS" == "completed" ]] && [[ -n "$target_branch" ]]; then
        if has_close_checkpoint "switched"; then
            log "${GREEN}✓${NC} Branch switch already recorded — skipping"
        else
            local current_now=$(git branch --show-current 2>/dev/null || echo "")
            if [[ "$current_now" != "$target_branch" ]]; then
                git checkout "$target_branch" >/dev/null 2>&1 || true
                log "${GREEN}✓${NC} Switched to $target_branch"
            fi
            write_close_checkpoint "switched"
        fi
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 5: Move docs to completed/ (AFTER merge succeeds)
    # ──────────────────────────────────────────────────────────────────

    if [[ "$STATUS" == "completed" ]] && has_close_checkpoint "docs_moved"; then
        log "${GREEN}✓${NC} Docs already moved in a prior run — skipping"
    elif [[ "$STATUS" == "completed" ]]; then
        local active_docs=$(find_by_id "$TASK_ID" | grep "/active/" || true)

        if [[ -n "$active_docs" ]]; then
            mkdir -p "${DOCS_DIR}/completed/${RANGE_FOLDER}"
            DOC_COUNT=0
            while IFS= read -r doc; do
                if [[ -n "$doc" ]] && [[ -f "$doc" ]]; then
                    local filename=$(basename "$doc")
                    local new_path="${DOCS_DIR}/completed/${RANGE_FOLDER}/${filename}"

                    mv "$doc" "$new_path"
                    git add "$new_path"

                    if [[ "$doc" == "$TASK_DOC" ]]; then
                        TASK_DOC="docs/completed/${RANGE_FOLDER}/${filename}"
                    fi

                    log "${GREEN}✓${NC} Moved: $filename"
                    ((DOC_COUNT++)) || true
                fi
            done <<< "$active_docs"

            git add docs/active/ 2>/dev/null || true
            log "${GREEN}✓${NC} Moved $DOC_COUNT document(s) to completed/${RANGE_FOLDER}/"
        fi

        # Update document index
        "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
        git add docs/DOCUMENT-INDEX.md 2>/dev/null || true
        git add docs/SEQUENCE-TRACKER.md 2>/dev/null || true

        # Commit doc moves
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "docs: close work item ${TASK_ID} - ${TASK_TITLE}

Moved ${DOC_COUNT} document(s) to completed folder.
Task completed and documented." >/dev/null 2>&1 || true
            log "${GREEN}✓${NC} Committed doc moves on $(git branch --show-current 2>/dev/null)"
        fi
        write_close_checkpoint "docs_moved"
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 6: Delete feature branch (completed tasks only)
    # ──────────────────────────────────────────────────────────────────

    if [[ "$STATUS" == "completed" ]] && [[ "$MERGED" == "true" ]] && has_close_checkpoint "branch_deleted"; then
        log "${GREEN}✓${NC} Branch deletion already recorded — skipping"
        DELETE_BRANCH=true
    elif [[ "$STATUS" == "completed" ]] && [[ "$MERGED" == "true" ]]; then
        # Protected branch guard — never delete branches configured in PROJECT.yaml ci.branches.*
        if is_protected_branch "$feature_branch"; then
            log "${RED}✗${NC} Refusing to delete protected branch: $feature_branch"
        elif [[ "$feature_branch" == "$DEFAULT_BRANCH" ]]; then
            log "${YELLOW}⚠${NC} Skipping deletion of default branch: $feature_branch"
        else
            # Delete local branch (-D force-delete is safe here because we just squash-merged all commits)
            git branch -d "$feature_branch" 2>/dev/null || git branch -D "$feature_branch" 2>/dev/null || true
            log "${GREEN}✓${NC} Deleted local branch: $feature_branch"
            DELETE_BRANCH=true

            # Delete remote branch (best-effort)
            git push origin --delete "$feature_branch" 2>/dev/null || true
            log "${BLUE}ℹ${NC} Deleted remote branch (if present): $feature_branch"
            write_close_checkpoint "branch_deleted"
        fi
    fi

    # ──────────────────────────────────────────────────────────────────
    # Step 9: Clean up .current-task if it references the closed branch
    # ──────────────────────────────────────────────────────────────────

    if [[ -f ".current-task" ]]; then
        local ct_branch=$(jq -r '.branch // empty' .current-task 2>/dev/null || echo "")
        if [[ "$ct_branch" == "$feature_branch" ]] || [[ -z "$ct_branch" ]]; then
            command rm -f .current-task
            log "${GREEN}✓${NC} Removed .current-task (referenced closed branch)"
        fi
    fi

    # Clean up lockfile (last step — persists through cleanup for retry safety)
    if [[ -f "$CLOSE_STATE_FILE" ]]; then
        command rm -f "$CLOSE_STATE_FILE"
        log "${GREEN}✓${NC} Removed .task-close-state lockfile"
    fi

    # Prune remote branches
    git remote prune origin >/dev/null 2>&1 || true

    log "${GREEN}✓${NC} Cleanup complete"

    # Return JSON response
    if [[ "$SECTION" == "cleanup" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "cleanup",
  "message": "Cleanup complete",
  "docs_moved": $DOC_COUNT,
  "merged": $MERGED,
  "merge_target": "$(echo "${MERGE_TARGET:-$DEFAULT_BRANCH}" | sed 's/"/\\"/g')",
  "feature_branch": "$(echo "$feature_branch" | sed 's/"/\\"/g')",
  "branch_deleted": $DELETE_BRANCH,
  "stashed": false,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

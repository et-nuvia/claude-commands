#!/usr/bin/env bash
# task-close-identify.sh - Task identification, state file helpers, and status determination
# Sourced by task-close.sh — shares globals, no standalone execution

[[ -n "${_TASK_CLOSE_IDENTIFY_LOADED:-}" ]] && return 0; _TASK_CLOSE_IDENTIFY_LOADED=1

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

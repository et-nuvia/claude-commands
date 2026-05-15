#!/usr/bin/env bash
# task-close-cleanup.sh - Move documents, clean up branches, Docker
# Sourced by task-close.sh — shares globals, no standalone execution

[[ -n "${_TASK_CLOSE_CLEANUP_LOADED:-}" ]] && return 0; _TASK_CLOSE_CLEANUP_LOADED=1

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

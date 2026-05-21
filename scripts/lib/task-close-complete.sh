#!/usr/bin/env bash
# task-close-complete.sh - Handle completed task (verify, capture, update, find PR)
# Sourced by task-close.sh — shares globals, no standalone execution

[[ -n "${_TASK_CLOSE_COMPLETE_LOADED:-}" ]] && return 0; _TASK_CLOSE_COMPLETE_LOADED=1

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
    # Previously this block held raw `gh issue close` / raw `curl PUT` calls
    # against the GitLab API — bypassing the lib/task-api.sh adapter that
    # task-capture and task-hold already route through. That left the Group
    # A/B refactor half-applied. Route through `task_close` so any backend
    # (asana / gitlab / github / none) is handled uniformly.
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

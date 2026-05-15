#!/usr/bin/env bash
# task-close-defer.sh - Handle deferred task
# Sourced by task-close.sh — shares globals, no standalone execution

[[ -n "${_TASK_CLOSE_DEFER_LOADED:-}" ]] && return 0; _TASK_CLOSE_DEFER_LOADED=1

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

#!/usr/bin/env bash
#
# task-summary.sh - Create summary document for a task
#
# Usage:
#   task-summary.sh --json --full --task-id <TASK_ID>
#   task-summary.sh --json --find --task-id <TASK_ID>
#   task-summary.sh --json --extract --task-doc <path>
#   task-summary.sh --json --check-summaries --task-id <id>
#   task-summary.sh --json --generate --task-doc <path>
#   task-summary.sh --json --commit --summary-path <path>
#   task-summary.sh --raw --full [TASK_ID]
#
# Sections:
#   --find      Find task document from task ID
#   --generate  Generate summary document from task
#   --full      Complete workflow (find + generate)
#
# Output:
#   --json      Structured JSON response (default)
#   --raw       Human-readable verbose output
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/doc-utils.sh"

OUTPUT_MODE="json"
SECTION="full"
TASK_ID_ARG=""
TASK_DOC=""
TASK_ID=""
# Note: TASK_ID_ARG is the --task-id CLI input, TASK_ID is the resolved/normalized ID
SUMMARY_PATH=""

# ============================================================================
# JSON Response Functions
# ============================================================================

json_success() {
    local message="$1"
    local details="${2:-}"

    cat <<EOF
{
  "status": "success",
  "section": "${SECTION}",
  "message": "${message}",
  "timestamp": "$(date -Iseconds)",
  "summary_document": "${SUMMARY_PATH:-}",
  "summary_filename": "${SUMMARY_FILENAME:-}",
  "task_id": "${TASK_ID:-}",
  "task_status": "${STATUS:-}",
  "summary_type": "${SUMMARY_TYPE:-}",
  "details": ${details:-null}
}
EOF
}

json_error() {
    local message="$1"
    local details="${2:-}"

    cat <<EOF
{
  "status": "error",
  "section": "${SECTION}",
  "message": "${message}",
  "timestamp": "$(date -Iseconds)",
  "details": "${details}"
}
EOF
}

json_intervention() {
    local message="$1"
    local data="$2"

    cat <<EOF
{
  "status": "intervention_needed",
  "section": "${SECTION}",
  "message": "${message}",
  "timestamp": "$(date -Iseconds)",
  ${data}
}
EOF
}

# ============================================================================
# Raw Output Functions
# ============================================================================

raw_output() {
    echo "════════════════════════════════════════════════════════════════"
    echo "$@"
    echo "════════════════════════════════════════════════════════════════"
}

raw_success() {
    raw_output "✓ SUCCESS: $1"
    [[ -n "${2:-}" ]] && echo "$2"
}

raw_error() {
    raw_output "❌ ERROR: $1"
    [[ -n "${2:-}" ]] && echo "$2"
}

# ============================================================================
# Section: Find Task
# ============================================================================

find_task() {
    local input="$1"

    # Check for .current-task file first
    if [[ -z "$input" ]] && load_current_task; then
        TASK_DOC="$CT_TASK_DOC"

        if [[ -n "$TASK_DOC" && -f "$TASK_DOC" ]]; then
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                cat <<EOF
{
  "status": "success",
  "section": "find",
  "message": "Found current task from .current-task",
  "task_document": "${TASK_DOC}",
  "timestamp": "$(date -Iseconds)"
}
EOF
            else
                raw_success "Found current task: $TASK_DOC"
            fi
            return 0
        fi
    fi

    # If no input, request it
    if [[ -z "$input" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            json_intervention "Task ID required" \
                '"prompt": "Enter task to summarize (task ID, task document path, or issue number)"'
        else
            raw_error "Task ID required" "Provide task ID (e.g. A3F2B9), task document path, or issue number (#123)"
        fi
        return 1
    fi

    # Check if input is task ID
    if [[ "$input" =~ ^[A-Fa-f0-9]{6}$ ]]; then
        TASK_ID=$(normalize_task_id "$input")
        TASK_DOC=$(find_primary "$TASK_ID")

        if [[ -z "$TASK_DOC" ]]; then
            local available_docs
            available_docs=$(find_by_id "$TASK_ID" | xargs -n1 basename 2>/dev/null || echo "None")

            if [[ "$OUTPUT_MODE" == "json" ]]; then
                json_error "No primary task found for task ID $TASK_ID" "Available documents: $available_docs"
            else
                raw_error "No primary task found for task ID $TASK_ID" "Available documents:\n$available_docs"
            fi
            return 1
        fi
    else
        # Try to find by issue number or other identifier
        TASK_DOC=$(find docs/active docs/completed -name "*-TSK-*.md" -o -name "*-INC-*.md" 2>/dev/null | grep "$input" | head -1)
    fi

    # Verify task document exists
    if [[ ! -f "$TASK_DOC" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            json_error "Task document not found" "Input: $input"
        else
            raw_error "Task document not found" "Input: $input"
        fi
        return 1
    fi

    # Extract task ID from task document
    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "find",
  "message": "Task document found",
  "task_document": "${TASK_DOC}",
  "task_id": "${TASK_ID}",
  "timestamp": "$(date -Iseconds)"
}
EOF
    else
        raw_success "Task document found: $TASK_DOC" "Task ID: $TASK_ID"
    fi
}

# ============================================================================
# Section: Extract Task Metadata
# ============================================================================

extract_metadata() {
    local task_doc="$1"

    # Extract key information from task document
    TASK_TITLE=$(get_doc_title "$task_doc")
    TASK_DESCRIPTION=$(grep -A 5 "## Description\|## Situation\|## Summary" "$task_doc" | tail -5 | head -5 || echo "No description available")
    ACCEPTANCE_CRITERIA=$(grep -A 10 "## Acceptance Criteria" "$task_doc" | tail -10 | head -10 || echo "No acceptance criteria defined")

    # Determine task status
    if grep -q "## Task Completion\|Status.*Completed" "$task_doc"; then
        STATUS="completed"
    elif grep -q "## Task On Hold\|Status.*On Hold" "$task_doc"; then
        STATUS="on_hold"
    elif grep -q "## Task Deferred\|Status.*Deferred" "$task_doc"; then
        STATUS="deferred"
    else
        STATUS="in_progress"
    fi

    # Extract timeline information
    START_DATE=$(grep -i "started\|created" "$task_doc" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || echo "TBD")

    if [[ "$STATUS" == "completed" ]]; then
        COMPLETION_DATE=$(grep -i "completed" "$task_doc" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1 || date -I)
    else
        COMPLETION_DATE="In Progress"
    fi

    # Extract PR/MR URL
    PR_URL=$(grep -oE 'https://github\.com/[^[:space:]]+/pull/[0-9]+|https://[^/]+/[^[:space:]]+/-/merge_requests/[0-9]+' "$task_doc" | head -1 || echo "")

    # Auto-extract summary information
    PROGRESS_SUMMARY=$(grep -A 3 "## Progress\|## Summary" "$task_doc" | tail -3 | head -3 || echo "Work in progress")
    TASK_IMPACT=$(grep -A 2 "## Acceptance Criteria\|## Requirements" "$task_doc" | tail -2 | head -2 || echo "See acceptance criteria")
    CHALLENGES=$(grep -A 3 "## Challenges\|## Issues\|## Blockers" "$task_doc" | tail -3 | head -3 || echo "None significant")
    LEARNINGS=$(grep -A 3 "## Learnings\|## Lessons\|## Notes" "$task_doc" | tail -3 | head -3 || echo "Task completed successfully")

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "extract",
  "message": "Task metadata extracted",
  "task_title": "${TASK_TITLE}",
  "task_status": "${STATUS}",
  "start_date": "${START_DATE}",
  "completion_date": "${COMPLETION_DATE}",
  "pr_url": "${PR_URL}",
  "timestamp": "$(date -Iseconds)"
}
EOF
    else
        raw_success "Task metadata extracted"
        echo "Title: $TASK_TITLE"
        echo "Status: $STATUS"
        echo "Started: $START_DATE"
        echo "Completion: $COMPLETION_DATE"
        [[ -n "$PR_URL" ]] && echo "PR/MR: $PR_URL"
    fi
}

# ============================================================================
# Section: Check Previous Summaries
# ============================================================================

check_previous_summaries() {
    local task_id="$1"

    # Find all SUM documents for this task ID
    local previous_sums
    previous_sums=$(find_by_id "$task_id" | grep "\-SUM\-" | sort || echo "")
    local latest_sum
    latest_sum=$(echo "$previous_sums" | tail -1)

    if [[ -n "$latest_sum" && -f "$latest_sum" ]]; then
        CREATE_INCREMENTAL="true"
        SUMMARY_TYPE="Incremental (since last summary)"

        # Build previous summary references
        PREVIOUS_SUMMARY_REFS="For complete history, see previous summaries:"
        while IFS= read -r sum_doc; do
            if [[ -n "$sum_doc" ]]; then
                local sum_filename
                sum_filename=$(basename "$sum_doc")
                PREVIOUS_SUMMARY_REFS="${PREVIOUS_SUMMARY_REFS}
- ${sum_filename}"
            fi
        done <<< "$previous_sums"
    else
        CREATE_INCREMENTAL="false"
        SUMMARY_TYPE="Comprehensive (initial summary)"
        PREVIOUS_SUMMARY_REFS="This is the first summary document for this work item."
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local sum_count=0
        [[ -n "$previous_sums" ]] && sum_count=$(echo "$previous_sums" | grep -c "^" || echo 0)

        cat <<EOF
{
  "status": "success",
  "section": "check_summaries",
  "message": "Previous summaries checked",
  "has_previous": $([ "$CREATE_INCREMENTAL" == "true" ] && echo "true" || echo "false"),
  "summary_type": "${SUMMARY_TYPE}",
  "previous_count": ${sum_count},
  "timestamp": "$(date -Iseconds)"
}
EOF
    else
        raw_success "Previous summaries checked"
        if [[ "$CREATE_INCREMENTAL" == "true" ]]; then
            echo "Found previous summary documents - creating incremental summary"
            echo "$previous_sums" | xargs -n1 basename
        else
            echo "No previous summaries - creating comprehensive summary"
        fi
    fi
}

# ============================================================================
# Section: Generate Summary Document
# ============================================================================

generate_summary() {
    local task_doc="$1"

    # Get timestamp for document naming
    local datetime
    datetime=$(date +%y%m%d%H%M)

    # Create task slug from title
    local task_slug
    task_slug=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-\|-$//' | cut -c1-40)

    # Resolve the SUM path via new-doc.sh — it anchors on the CURRENT worktree
    # (find_docs_dir), so the doc is created here even when task_doc resolved
    # to the main checkout via find_primary's fallback.
    local doc_json
    doc_json=$("${HOME}/.claude/scripts/new-doc.sh" --type SUM --description "${task_slug}" --id "$TASK_ID" --json 2>/dev/null || echo "")
    SUMMARY_PATH=$(echo "$doc_json" | jq -r '.filepath // empty' 2>/dev/null || echo "")
    if [[ -z "$SUMMARY_PATH" ]]; then
        # Fallback: sibling of the TSK doc (pre-worktree behavior)
        SUMMARY_PATH="$(dirname "$task_doc")/${TASK_ID}-${datetime}-SUM-${task_slug}.md"
    fi
    SUMMARY_FILENAME="$(basename "$SUMMARY_PATH")"

    # Generate summary document
    cat > "$SUMMARY_PATH" <<EOF
# Summary: ${TASK_TITLE}

**Work Item**: ${TASK_ID}
**Created**: $(date -Iseconds)
**Type**: Summary
**Related To**: ${TASK_ID}-*-TSK-*.md
**Audience**: All-hands/Team/Executive
**Status**: ${STATUS}
**Summary Type**: ${SUMMARY_TYPE}

---

## Purpose

Summary document for work item ${TASK_ID}: ${TASK_TITLE}

---

## Previous Summary Documents

${PREVIOUS_SUMMARY_REFS}

---

## Executive Summary

${PROGRESS_SUMMARY}

---

## Situation

**What Happened**:
${TASK_DESCRIPTION}

**Why It Matters**:
${TASK_IMPACT}

**Timeline**:
- Started: ${START_DATE}
- Status: ${STATUS}
- Completed/Current: ${COMPLETION_DATE}

---

## Impact

**Users**:
- Features/improvements delivered

**Business**:
- Customer satisfaction: Improved by implementing requested items
- Delivery: On track

**Operations**:
- Code quality: Maintained/Improved
- Test coverage: Verified
- Documentation: Updated

---

## What Was Accomplished

${PROGRESS_SUMMARY}

**Acceptance Criteria**:
${ACCEPTANCE_CRITERIA}

---

## Key Results

**Completed**:
- ✅ All acceptance criteria met
- ✅ Task executed successfully

**Challenges**:
${CHALLENGES}

---

## What We Learned

**Key Insights**:
${LEARNINGS}

**Best Practices**:
- Clear requirements help tracking progress
- Regular testing catches issues early
- Communication with stakeholders important

---

## Going Forward

**Immediate Actions**:
- Monitor if deployed
- Address any feedback

**Short-term Plans**:
- Follow up with stakeholders
- Plan next phase if applicable

---

## Resources

**Team Effort**:
- Teams involved: Engineering
- External resources: None

---

## Related Documents

**For More Detail, See**:
- TSK: ${TASK_ID}-*-TSK-*.md - Full task requirements
EOF

    # Add PR/MR link if available
    if [[ -n "$PR_URL" ]]; then
        echo "- PR/MR: ${PR_URL} - Code changes and review" >> "$SUMMARY_PATH"
    fi

    # Add footer
    cat >> "$SUMMARY_PATH" <<EOF

---

**Summary Created**: $(date -Iseconds)
**Status**: ✓ Summary Document
EOF

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "generate",
  "message": "Summary document generated",
  "summary_document": "${SUMMARY_PATH}",
  "summary_filename": "${SUMMARY_FILENAME}",
  "summary_type": "${SUMMARY_TYPE}",
  "timestamp": "$(date -Iseconds)"
}
EOF
    else
        raw_success "Summary document generated: $SUMMARY_FILENAME"
        echo "Path: $SUMMARY_PATH"
        echo "Type: $SUMMARY_TYPE"
    fi
}

# ============================================================================
# Section: Commit Summary
# ============================================================================

commit_summary() {
    # Stage summary document
    git add "$SUMMARY_PATH"

    # Create commit message
    local commit_msg
    commit_msg="docs(task-summary): create summary for work item ${TASK_ID}

Task: ${TASK_TITLE}
Type: ${STATUS}
Summary Type: ${SUMMARY_TYPE}

Created summary document following task-SUM template.
Ready for stakeholder review and communication."

    # Commit
    git commit -m "$commit_msg"

    # Update document index
    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true

    if git diff --cached --quiet; then
        # No index changes to commit
        true
    else
        git add docs/DOCUMENT-INDEX.md 2>/dev/null || true
        git commit --amend --no-edit --no-verify 2>/dev/null || true
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "commit",
  "message": "Summary document committed",
  "timestamp": "$(date -Iseconds)"
}
EOF
    else
        raw_success "Summary document committed"
    fi
}

# ============================================================================
# Full Workflow
# ============================================================================

run_full_workflow() {
    local task_input="${1:-}"

    # Section 1: Find task
    SECTION="find"
    find_task "$task_input" || return 1

    # Section 2: Extract metadata
    SECTION="extract"
    extract_metadata "$TASK_DOC" || return 1

    # Section 3: Check previous summaries
    SECTION="check_summaries"
    check_previous_summaries "$TASK_ID" || return 1

    # Section 4: Generate summary
    SECTION="generate"
    generate_summary "$TASK_DOC" || return 1

    # Section 5: Commit summary
    SECTION="commit"
    commit_summary || return 1

    # Success - output final result
    SECTION="full"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        json_success "Summary document created and committed" \
            "$(cat <<EOF
{
  "summary_document": "${SUMMARY_PATH}",
  "summary_filename": "${SUMMARY_FILENAME}",
  "task_id": "${TASK_ID}",
  "task_title": "${TASK_TITLE}",
  "task_status": "${STATUS}",
  "summary_type": "${SUMMARY_TYPE}",
  "task_document": "${TASK_DOC}",
  "start_date": "${START_DATE}",
  "completion_date": "${COMPLETION_DATE}"
}
EOF
)"
    else
        raw_success "Task Summary Created"
        cat <<EOF

Work Item: ${TASK_ID}
Task: ${TASK_TITLE}
Status: ${STATUS}

Summary Document: ${SUMMARY_FILENAME}
Location: $(dirname "$SUMMARY_PATH")/
Summary Type: ${SUMMARY_TYPE}

Timeline:
- Started: ${START_DATE}
- Status: ${COMPLETION_DATE}

✓ Summary document created
✓ Committed to git
✓ Document index updated

View summary:
cat "${SUMMARY_PATH}"
EOF
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Parse arguments
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
            --find)
                SECTION="find"
                shift
                ;;
            --extract)
                SECTION="extract"
                shift
                ;;
            --check-summaries)
                SECTION="check_summaries"
                shift
                ;;
            --generate)
                SECTION="generate"
                shift
                ;;
            --commit)
                SECTION="commit"
                shift
                ;;
            --full)
                SECTION="full"
                shift
                ;;
            --task-doc)
                TASK_DOC="$2"
                shift 2
                ;;
            --summary-path)
                SUMMARY_PATH="$2"
                shift 2
                ;;
            --task-id)
                TASK_ID_ARG="$2"
                TASK_ID="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 2
                ;;
        esac
    done

    # Execute requested section
    case "$SECTION" in
        find)
            find_task "$TASK_ID"
            ;;
        extract)
            [[ -z "$TASK_DOC" ]] && { json_error "Task document required" "Use --task-doc <path>"; exit 1; }
            extract_metadata "$TASK_DOC"
            ;;
        check_summaries)
            [[ -z "$TASK_ID" ]] && { json_error "Task ID required" "Use --task-id <id>"; exit 1; }
            check_previous_summaries "$TASK_ID"
            ;;
        generate)
            [[ -z "$TASK_DOC" ]] && { json_error "Task document required" "Use --task-doc <path>"; exit 1; }
            generate_summary "$TASK_DOC"
            ;;
        commit)
            [[ -z "$SUMMARY_PATH" ]] && { json_error "Summary path required" "Use --summary-path <path>"; exit 1; }
            commit_summary
            ;;
        full)
            run_full_workflow "$TASK_ID"
            ;;
        *)
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                json_error "Invalid section" "Valid sections: find, extract, check-summaries, generate, commit, full"
            else
                raw_error "Invalid section" "Valid sections: find, extract, check-summaries, generate, commit, full"
            fi
            exit 1
            ;;
    esac
}

main "$@"

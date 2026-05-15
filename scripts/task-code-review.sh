#!/usr/bin/env bash
set -euo pipefail

# task-code-review.sh - Create a code review document for a task
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-code-review.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --identify-task:    Identify and load task document
#   --get-pr:           Get PR/MR or detect branch diff source
#   --gather-info:      Gather diff stats, file list, commit log (summary only)
#   --diff-page N:      Return page N of the diff (200 lines per page)
#   --create-doc:       Create code review document
#   --commit:           Commit document to git
#   --full:             Run identify → get-pr → gather-info (returns summary + page count)
#
# Two-Phase Review Pattern:
#   1. LLM calls: --full → gets summary, stats, file list, commit log, diff_pages count
#   2. LLM calls: --diff-page 1, --diff-page 2, ... to read the full diff
#   3. LLM calls: --create-doc → creates CRV document skeleton
#   4. LLM edits CRV with findings using Edit tool
#   5. LLM calls: --commit → commits the document
#
# Diff Source Priority:
#   1. GitHub PR (if gh available and PR exists)
#   2. GitLab MR (if glab available and MR exists)
#   3. git diff against default branch (always available)

DIFF_LINES_PER_PAGE=200

# Global variables
OUTPUT_MODE="json"
SECTION="full"
TASK_INPUT=""
DIFF_PAGE=0

# Task context
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
TASK_SLUG=""
TASK_BRANCH=""

# PR/MR context
PR_URL=""
PR_TYPE=""
PR_NUM=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""
FILES_CHANGED=0
ADDITIONS=0
DELETIONS=0
PLATFORM=""
DIFF_SOURCE=""  # "pr", "mr", or "branch"

# Diff capture
DIFF_FILE=""
DIFF_STATS=""
FILE_LIST=""
COMMIT_LOG=""
DIFF_TOTAL_LINES=0
DIFF_PAGES=0

# Review details
REVIEWER=""
REVIEW_TYPE_NAME=""
CRV_FILENAME=""
CRV_PATH=""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/git-utils.sh"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

# Stable path for this task's diff file (survives across calls)
get_diff_path() {
    local task_id="${1:-unknown}"
    echo "/tmp/crv-diff-${task_id}.diff"
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Identify task
section_identify_task() {
    log "${BLUE}Identifying Task${NC}"

    if [[ ! -f "${SCRIPT_DIR}/doc-utils.sh" ]]; then
        exit_with_json "error" "doc-utils.sh not found" "Required utility script missing"
    fi
    source "${SCRIPT_DIR}/doc-utils.sh"

    # Priority: explicit --task-id > .current-task > error
    if [[ -n "$TASK_INPUT" ]]; then
        if [[ "$TASK_INPUT" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$TASK_INPUT")
            TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || echo "")
            if [[ -z "$TASK_DOC" ]]; then
                exit_with_json "error" "No primary task found for task ID $TASK_ID" "Run: /task-fetch to see available tasks"
            fi
            log "${GREEN}✓${NC} Found task by ID: $TASK_DOC"
        else
            TASK_DOC=$(find docs/active docs/completed -name "*-TSK-*.md" 2>/dev/null | grep "$TASK_INPUT" | head -1 || echo "")
            log "${GREEN}✓${NC} Found task by name: $TASK_DOC"
        fi
    elif load_current_task; then
        TASK_DOC="$CT_TASK_DOC"
        TASK_BRANCH="$CT_BRANCH"
        TASK_ID="$CT_TASK_ID"
        log "${GREEN}✓${NC} Found current task: $TASK_DOC"
    fi

    if [[ ! -f "${TASK_DOC:-}" ]]; then
        exit_with_json "error" "Task document not found" "Provide task ID or use /task-start first"
    fi

    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
    TASK_TITLE=$(get_doc_title "$TASK_DOC")
    TASK_SLUG=$(basename "$TASK_DOC" | sed -E 's/^[A-F0-9]{6}-[0-9]{10}-[A-Z]{3}-//' | sed 's/.md$//' | head -c 40 | sed 's/-$//')

    log "${GREEN}✓${NC} Task identified: $TASK_ID - $TASK_TITLE"

    if [[ "$SECTION" == "identify-task" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg task_doc "$TASK_DOC" \
            --arg task_title "$TASK_TITLE" \
            --arg task_slug "$TASK_SLUG" \
            --arg task_branch "$TASK_BRANCH" \
            '{status:"success", section:"identify-task", task_id:$task_id, task_doc:$task_doc, task_title:$task_title, task_slug:$task_slug, task_branch:$task_branch}')"
        exit 0
    fi
}

# Section 2: Get PR/MR or detect branch diff source
section_get_pr() {
    log "${BLUE}Detecting Diff Source${NC}"

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    DEFAULT_BRANCH=$(detect_base_branch)

    if [[ -z "$PR_URL" ]] && [[ -n "$CURRENT_BRANCH" ]]; then
        if command -v gh &>/dev/null && git remote -v 2>/dev/null | grep -q "github"; then
            PLATFORM="github"
            PR_TYPE="PR"
            PR_URL=$(gh pr list --head "$CURRENT_BRANCH" --state all --json url --jq '.[0].url' 2>/dev/null || echo "")
            if [[ -n "$PR_URL" ]]; then
                PR_NUM=$(echo "$PR_URL" | sed -n 's|.*/pull/\([0-9]\+\).*|\1|p' || echo "")
                DIFF_SOURCE="pr"
                log "${GREEN}✓${NC} Found GitHub PR: $PR_URL"
            fi
        elif command -v glab &>/dev/null && git remote -v 2>/dev/null | grep -q "gitlab"; then
            PLATFORM="gitlab"
            PR_TYPE="MR"
            local mr_url
            mr_url=$(glab mr list --source-branch "$CURRENT_BRANCH" 2>/dev/null | head -1 | awk '{print $1}' || echo "")
            if [[ -n "$mr_url" ]]; then
                PR_URL="$mr_url"
                PR_NUM=$(echo "$PR_URL" | sed -n 's|.*/-/merge_requests/\([0-9]\+\).*|\1|p' || echo "")
                DIFF_SOURCE="mr"
                log "${GREEN}✓${NC} Found GitLab MR: $PR_URL"
            fi
        fi
    elif [[ -n "$PR_URL" ]]; then
        if [[ "$PR_URL" == *"github"* ]]; then
            PLATFORM="github"; PR_TYPE="PR"
            PR_NUM=$(echo "$PR_URL" | sed -n 's|.*/pull/\([0-9]\+\).*|\1|p' || echo "")
            DIFF_SOURCE="pr"
        elif [[ "$PR_URL" == *"gitlab"* ]] || [[ "$PR_URL" == *"merge_request"* ]]; then
            PLATFORM="gitlab"; PR_TYPE="MR"
            PR_NUM=$(echo "$PR_URL" | sed -n 's|.*/-/merge_requests/\([0-9]\+\).*|\1|p' || echo "")
            DIFF_SOURCE="mr"
        fi
    fi

    if [[ -z "$DIFF_SOURCE" ]]; then
        DIFF_SOURCE="branch"
        PR_TYPE="Branch diff"
        log "${YELLOW}⚠${NC} No PR/MR found — using git diff against ${DEFAULT_BRANCH}"
    fi

    if [[ "$SECTION" == "get-pr" ]]; then
        log_json "$(jq -nc \
            --arg platform "$PLATFORM" --arg pr_url "$PR_URL" --arg pr_type "$PR_TYPE" \
            --arg diff_source "$DIFF_SOURCE" --arg current "$CURRENT_BRANCH" --arg default "$DEFAULT_BRANCH" \
            '{status:"success", section:"get-pr", platform:$platform, pr_url:$pr_url, pr_type:$pr_type, diff_source:$diff_source, current_branch:$current, default_branch:$default}')"
        exit 0
    fi
}

# Section 3: Gather diff stats, file list, commit log — write diff to file
section_gather_info() {
    log "${BLUE}Gathering Review Information${NC}"

    DIFF_FILE=$(get_diff_path "$TASK_ID")

    if [[ "$DIFF_SOURCE" == "pr" ]] && [[ -n "$PR_NUM" ]]; then
        gh pr diff "$PR_NUM" > "$DIFF_FILE" 2>/dev/null || true
        local pr_info
        pr_info=$(gh pr view "$PR_NUM" --json files,additions,deletions,commits 2>/dev/null || echo "{}")
        FILES_CHANGED=$(echo "$pr_info" | jq -r '.files | length' 2>/dev/null || echo "0")
        ADDITIONS=$(echo "$pr_info" | jq -r '.additions' 2>/dev/null || echo "0")
        DELETIONS=$(echo "$pr_info" | jq -r '.deletions' 2>/dev/null || echo "0")
        FILE_LIST=$(echo "$pr_info" | jq -r '.files[].path' 2>/dev/null || echo "")
        COMMIT_LOG=$(gh pr view "$PR_NUM" --json commits --jq '.commits[].messageHeadline' 2>/dev/null || echo "")
        DIFF_STATS=$(git diff --stat "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")

    elif [[ "$DIFF_SOURCE" == "mr" ]] && [[ -n "$PR_NUM" ]]; then
        glab mr diff "$PR_NUM" > "$DIFF_FILE" 2>/dev/null || \
            git diff "origin/${DEFAULT_BRANCH}...HEAD" > "$DIFF_FILE" 2>/dev/null || true
        FILE_LIST=$(git diff --name-only "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
        COMMIT_LOG=$(git log --oneline "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        DIFF_STATS=$(git diff --stat "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
        FILES_CHANGED=$(echo "$FILE_LIST" | grep -c '.' || echo "0")
        local numstat
        numstat=$(git diff --numstat "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
        ADDITIONS=$(echo "$numstat" | awk '{s+=$1} END {print s+0}')
        DELETIONS=$(echo "$numstat" | awk '{s+=$2} END {print s+0}')

    else
        git diff "${DEFAULT_BRANCH}...HEAD" > "$DIFF_FILE" 2>/dev/null || \
            git diff "${DEFAULT_BRANCH}..HEAD" > "$DIFF_FILE" 2>/dev/null || true
        FILE_LIST=$(git diff --name-only "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || \
            git diff --name-only "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        COMMIT_LOG=$(git log --oneline "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        DIFF_STATS=$(git diff --stat "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || \
            git diff --stat "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        FILES_CHANGED=$(echo "$FILE_LIST" | grep -c '.' || echo "0")
        local numstat
        numstat=$(git diff --numstat "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || \
            git diff --numstat "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        ADDITIONS=$(echo "$numstat" | awk '{s+=$1} END {print s+0}')
        DELETIONS=$(echo "$numstat" | awk '{s+=$2} END {print s+0}')
    fi

    # Ensure numeric values for jq --argjson
    FILES_CHANGED="${FILES_CHANGED:-0}"; [[ "$FILES_CHANGED" =~ ^[0-9]+$ ]] || FILES_CHANGED=0
    ADDITIONS="${ADDITIONS:-0}"; [[ "$ADDITIONS" =~ ^[0-9]+$ ]] || ADDITIONS=0
    DELETIONS="${DELETIONS:-0}"; [[ "$DELETIONS" =~ ^[0-9]+$ ]] || DELETIONS=0

    # Compute page count
    DIFF_TOTAL_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo "0")
    DIFF_TOTAL_LINES="${DIFF_TOTAL_LINES// /}"  # wc -l may have leading spaces
    DIFF_PAGES=$(( (DIFF_TOTAL_LINES + DIFF_LINES_PER_PAGE - 1) / DIFF_LINES_PER_PAGE ))
    [[ $DIFF_PAGES -eq 0 ]] && DIFF_PAGES=1

    log "${GREEN}✓${NC} Diff: ${DIFF_TOTAL_LINES} lines (${DIFF_PAGES} pages), ${FILES_CHANGED} files, +${ADDITIONS}/-${DELETIONS}"

    if [[ "$SECTION" == "gather-info" ]]; then
        log_json "$(jq -nc \
            --arg diff_source "$DIFF_SOURCE" \
            --arg diff_stats "$DIFF_STATS" --arg file_list "$FILE_LIST" --arg commit_log "$COMMIT_LOG" \
            --argjson files "$FILES_CHANGED" --argjson adds "$ADDITIONS" --argjson dels "$DELETIONS" \
            --argjson lines "$DIFF_TOTAL_LINES" --argjson pages "$DIFF_PAGES" \
            '{status:"success", section:"gather-info", diff_source:$diff_source, stats:{files_changed:$files, additions:$adds, deletions:$dels}, diff:{total_lines:$lines, pages:$pages, lines_per_page:200}, diff_stats:$diff_stats, file_list:$file_list, commit_log:$commit_log}')"
        exit 0
    fi
}

# Section: Return a specific page of the diff
section_diff_page() {
    log "${BLUE}Returning Diff Page ${DIFF_PAGE}${NC}"

    DIFF_FILE=$(get_diff_path "$TASK_ID")

    if [[ ! -f "$DIFF_FILE" ]]; then
        exit_with_json "error" "Diff file not found — run --full or --gather-info first" ""
    fi

    DIFF_TOTAL_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo "0")
    DIFF_PAGES=$(( (DIFF_TOTAL_LINES + DIFF_LINES_PER_PAGE - 1) / DIFF_LINES_PER_PAGE ))
    [[ $DIFF_PAGES -eq 0 ]] && DIFF_PAGES=1

    if [[ $DIFF_PAGE -lt 1 ]] || [[ $DIFF_PAGE -gt $DIFF_PAGES ]]; then
        exit_with_json "error" "Invalid page ${DIFF_PAGE} — valid range is 1..${DIFF_PAGES}" ""
    fi

    local start_line=$(( (DIFF_PAGE - 1) * DIFF_LINES_PER_PAGE + 1 ))
    local page_content
    page_content=$(sed -n "${start_line},$((start_line + DIFF_LINES_PER_PAGE - 1))p" "$DIFF_FILE")
    local page_lines
    page_lines=$(echo "$page_content" | wc -l)

    log_json "$(jq -nc \
        --argjson page "$DIFF_PAGE" \
        --argjson total_pages "$DIFF_PAGES" \
        --argjson start_line "$start_line" \
        --argjson lines "$page_lines" \
        --arg content "$page_content" \
        '{status:"success", section:"diff-page", page:$page, total_pages:$total_pages, start_line:$start_line, lines:$lines, content:$content}')"
    exit 0
}

# Find existing CRV document for this task (most recent)
find_existing_crv() {
    local task_dir
    task_dir="$(dirname "$TASK_DOC")"
    # Find CRV files for this task ID, sorted newest first
    local found
    found=$(find "$task_dir" -name "${TASK_ID}-*-CRV-*.md" 2>/dev/null | sort -r | head -1)
    if [[ -n "$found" ]]; then
        CRV_PATH="$found"
        CRV_FILENAME="$(basename "$found")"
        return 0
    fi
    return 1
}

# Section: Create code review document
section_create_doc() {
    log "${BLUE}Creating Code Review Document${NC}"

    # If a CRV already exists for this task, use it instead of creating a new one
    if find_existing_crv; then
        log "${GREEN}✓${NC} Found existing CRV: $CRV_FILENAME"
        if [[ "$SECTION" == "create-doc" ]]; then
            log_json "$(jq -nc \
                --arg crv_filename "$CRV_FILENAME" --arg crv_path "$CRV_PATH" \
                '{status:"success", section:"create-doc", next_action:"display_summary", crv_filename:$crv_filename, crv_path:$crv_path, message:"Existing CRV found — edit sections with findings, then call --commit"}')"
            exit 0
        fi
        return
    fi

    local datetime
    datetime=$(date +%y%m%d%H%M)
    CRV_FILENAME="${TASK_ID}-${datetime}-CRV-${TASK_SLUG}.md"
    CRV_PATH="$(dirname "$TASK_DOC")/${CRV_FILENAME}"

    if [[ -z "$REVIEWER" ]]; then
        REVIEWER=$(git config user.name 2>/dev/null || echo "Unknown")
    fi
    if [[ -z "$REVIEW_TYPE_NAME" ]]; then
        REVIEW_TYPE_NAME="Comprehensive review"
    fi

    local ref_label="$PR_TYPE"
    local ref_value="$PR_URL"
    if [[ "$DIFF_SOURCE" == "branch" ]] || [[ -z "$ref_value" ]]; then
        ref_label="Branch diff"
        ref_value="${CURRENT_BRANCH} vs ${DEFAULT_BRANCH}"
    fi

    # Build template content with known values filled in, placeholders for LLM
    local crv_template
    crv_template="# Code Review: ${TASK_TITLE}

**Work Item**: ${TASK_ID}
**Created**: $(date -Iseconds)
**Type**: Code Review
**Related To**: $(basename "$TASK_DOC")
**Reviewer**: ${REVIEWER}
**Review Status**: Complete

---

## Purpose

Code review for work item ${TASK_ID}: ${TASK_TITLE}
Review Type: ${REVIEW_TYPE_NAME}

---

## What Was Reviewed

**Scope**:
- **Source**: ${ref_label}
- **Reference**: ${ref_value}
- **Branch**: ${CURRENT_BRANCH}
- **Base**: ${DEFAULT_BRANCH}
- **Files Changed**: ${FILES_CHANGED}
- **Lines Changed**: +${ADDITIONS}/-${DELETIONS}

---

## Summary Assessment

| Category | Rating | Comment |
|----------|--------|---------|
| **Code Quality** | [LLM to fill in] | |
| **Security** | [LLM to fill in] | |
| **Performance** | [LLM to fill in] | |
| **Testing** | [LLM to fill in] | |
| **Documentation** | [LLM to fill in] | |

---

## Code Quality Review

### Architecture & Design

**Strengths**:
- [LLM to fill in]

**Concerns**:
- [LLM to fill in]

---

## Security Review

**Implemented**:
- [LLM to fill in]

**Missing or Needs Review**:
- [LLM to fill in]

---

## Performance Review

**Optimizations**:
- [LLM to fill in]

**Potential Issues**:
- [LLM to fill in]

---

## Testing Review

**Coverage Assessment**:
- **Status**: [LLM to determine]

**Test Quality**:
- [LLM to assess]

---

## Documentation Review

**Present**:
- [LLM to fill in]

**Missing**:
- [LLM to fill in]

---

## Requested Changes

### Must Fix (Blocking)

[LLM to fill in]

### Should Fix (Recommended)

[LLM to fill in]

### Nice to Have (Polish)

[LLM to fill in]

---

## Approval Status

**Current Status**: Pending Analysis

---

## Related Documents

- TSK: $(basename "$TASK_DOC")
- ${ref_label}: ${ref_value}"

    log "${GREEN}✓${NC} Prepared: $CRV_FILENAME"

    if [[ "$SECTION" == "create-doc" ]]; then
        log_json "$(jq -nc \
            --arg crv_filename "$CRV_FILENAME" --arg crv_path "$CRV_PATH" \
            --arg template "$crv_template" \
            '{status:"success", section:"create-doc", next_action:"write_document", crv_filename:$crv_filename, crv_path:$crv_path, template:$template, message:"Write completed CRV to crv_path using Write tool, then call --commit"}')"
        exit 0
    fi
}

# Section: Commit code review document
# Review notes checkpoint file — lets long diff-analysis survive interruption.
# The LLM can save partial findings as it pages through a large diff; a resumed
# session can load them instead of re-reading the whole diff from scratch.
REVIEW_NOTES_FILE=".task-code-review-state.json"

section_save_notes() {
    section_identify_task

    if [[ -z "${REVIEW_NOTES_JSON:-}" ]]; then
        exit_with_json "error" "No notes provided" "Pass --notes '<json>' with findings so far"
    fi
    if ! echo "$REVIEW_NOTES_JSON" | jq empty 2>/dev/null; then
        exit_with_json "error" "Invalid JSON in --notes" "Must be valid JSON (array or object)"
    fi

    jq -n \
        --arg task_id "$TASK_ID" \
        --arg updated "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson notes "$REVIEW_NOTES_JSON" \
        '{task_id: $task_id, updated: $updated, notes: $notes}' \
        > "$REVIEW_NOTES_FILE"

    log "${GREEN}✓${NC} Review notes saved to $REVIEW_NOTES_FILE"

    if [[ "$SECTION" == "save-notes" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg file "$REVIEW_NOTES_FILE" \
            '{status:"success", section:"save-notes", next_action:"display_summary", task_id:$task_id, state_file:$file, message:"Notes saved — safe to resume if analysis is interrupted"}')"
        exit 0
    fi
}

section_load_notes() {
    section_identify_task

    if [[ ! -f "$REVIEW_NOTES_FILE" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            '{status:"success", section:"load-notes", next_action:"analyze_code", task_id:$task_id, state_file:null, notes:null, message:"No prior review notes — start analysis fresh"}')"
        exit 0
    fi

    local state_task_id
    state_task_id=$(jq -r '.task_id // empty' "$REVIEW_NOTES_FILE" 2>/dev/null || echo "")
    if [[ "$state_task_id" != "$TASK_ID" ]]; then
        log "${YELLOW}⚠${NC} Notes file is for task $state_task_id, not $TASK_ID — ignoring"
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg other "$state_task_id" \
            '{status:"success", section:"load-notes", next_action:"analyze_code", task_id:$task_id, state_file:null, notes:null, warning:("Ignored state from other task: " + $other)}')"
        exit 0
    fi

    log "${GREEN}✓${NC} Loaded review notes from $REVIEW_NOTES_FILE"
    log_json "$(jq --arg section "load-notes" \
                   --arg next "resume_review" \
                   '. + {status:"success", section:$section, next_action:$next}' \
                   "$REVIEW_NOTES_FILE")"
    exit 0
}

section_commit() {
    log "${BLUE}Committing Code Review Document${NC}"

    if [[ ! -f "${CRV_PATH:-}" ]]; then
        exit_with_json "error" "Code review document not found" "Run --create-doc first"
    fi

    git add "$CRV_PATH"

    local ref_text="$PR_URL"
    if [[ "$DIFF_SOURCE" == "branch" ]] || [[ -z "$ref_text" ]]; then
        ref_text="${CURRENT_BRANCH} vs ${DEFAULT_BRANCH}"
    fi

    git commit -m "docs(code-review): create review for work item ${TASK_ID}

Task: ${TASK_TITLE}
Review Type: ${REVIEW_TYPE_NAME}
Reference: ${ref_text}"

    log "${GREEN}✓${NC} Committed"

    # Clean up temp diff file
    local diff_tmp
    diff_tmp=$(get_diff_path "$TASK_ID")
    [[ -f "$diff_tmp" ]] && rm -f "$diff_tmp"

    if [[ -f "${SCRIPT_DIR}/update-docs.sh" ]]; then
        "${SCRIPT_DIR}/update-docs.sh" &>/dev/null || true
        git add docs/DOCUMENT-INDEX.md &>/dev/null || true
    fi

    # CRV is persisted — review notes checkpoint is no longer needed.
    if [[ -f "$REVIEW_NOTES_FILE" ]]; then
        rm -f "$REVIEW_NOTES_FILE"
        log "${GREEN}✓${NC} Cleared review notes checkpoint"
    fi

    if [[ "$SECTION" == "commit" ]]; then
        log_json "$(jq -nc \
            --arg crv_filename "$CRV_FILENAME" --arg commit "$(git rev-parse HEAD)" \
            '{status:"success", section:"commit", next_action:"display_summary", crv_filename:$crv_filename, commit:$commit}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)           OUTPUT_MODE="json"; shift ;;
            --raw)            OUTPUT_MODE="raw"; shift ;;
            --full)           SECTION="full"; shift ;;
            --identify-task)  SECTION="identify-task"; shift ;;
            --get-pr)         SECTION="get-pr"; shift ;;
            --gather-info)    SECTION="gather-info"; shift ;;
            --diff-page)      SECTION="diff-page"; DIFF_PAGE="$2"; shift 2 ;;
            --create-doc)     SECTION="create-doc"; shift ;;
            --commit)         SECTION="commit"; shift ;;
            --save-notes)     SECTION="save-notes"; shift ;;
            --load-notes)     SECTION="load-notes"; shift ;;
            --notes)          REVIEW_NOTES_JSON="$2"; shift 2 ;;
            --reviewer)       REVIEWER="$2"; shift 2 ;;
            --review-type)    REVIEW_TYPE_NAME="$2"; shift 2 ;;
            --pr-url)         PR_URL="$2"; shift 2 ;;
            --task-id)        TASK_INPUT="$2"; shift 2 ;;
            *)                echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        identify-task)
            section_identify_task
            ;;
        get-pr)
            section_identify_task
            section_get_pr
            ;;
        gather-info)
            section_identify_task
            section_get_pr
            section_gather_info
            ;;
        diff-page)
            section_identify_task
            section_diff_page
            ;;
        create-doc)
            section_identify_task
            section_get_pr
            section_gather_info
            section_create_doc
            ;;
        commit)
            section_identify_task
            section_get_pr
            # Find existing CRV — don't create a new one
            if ! find_existing_crv; then
                exit_with_json "error" "No CRV document found for task ${TASK_ID}" "Run --create-doc first, edit it, then --commit"
            fi
            section_commit
            ;;
        save-notes)
            section_save_notes
            ;;
        load-notes)
            section_load_notes
            ;;
        full)
            section_identify_task
            section_get_pr
            section_gather_info

            # Return summary + page count — LLM reads pages then creates doc
            log_json "$(jq -nc \
                --arg next_action "analyze_code" \
                --arg task_id "$TASK_ID" --arg task_title "$TASK_TITLE" --arg task_doc "$TASK_DOC" \
                --arg diff_source "$DIFF_SOURCE" \
                --arg pr_url "$PR_URL" --arg pr_type "$PR_TYPE" --arg platform "$PLATFORM" \
                --arg current "$CURRENT_BRANCH" --arg default "$DEFAULT_BRANCH" \
                --argjson files "$FILES_CHANGED" --argjson adds "$ADDITIONS" --argjson dels "$DELETIONS" \
                --arg diff_file "$DIFF_FILE" \
                --argjson diff_lines "$DIFF_TOTAL_LINES" --argjson diff_pages "$DIFF_PAGES" \
                --arg diff_stats "$DIFF_STATS" --arg file_list "$FILE_LIST" --arg commit_log "$COMMIT_LOG" \
                '{
                    status: "success",
                    next_action: $next_action,
                    task: {task_id: $task_id, title: $task_title, doc: $task_doc},
                    diff_source: $diff_source,
                    pr: {url: $pr_url, type: $pr_type, platform: $platform},
                    branch: {current: $current, default: $default},
                    stats: {files_changed: $files, additions: $adds, deletions: $dels},
                    diff: {file: $diff_file, total_lines: $diff_lines, pages: $diff_pages, lines_per_page: 200},
                    diff_stats: $diff_stats,
                    file_list: $file_list,
                    commit_log: $commit_log
                }')"
            exit 0
            ;;
        *)
            exit_with_json "error" "Unknown section: $SECTION" "Valid: identify-task, get-pr, gather-info, diff-page N, create-doc, commit, full"
            ;;
    esac
}

main "$@"

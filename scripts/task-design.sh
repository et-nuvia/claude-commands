#!/usr/bin/env bash
set -euo pipefail

# task-design.sh - Create a design document (DSN) for a task
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-design.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --identify:    Identify and load task document
#   --create-doc:  Create DSN document skeleton via new-doc.sh, return template for LLM to fill
#   --commit:      Stage and commit populated DSN doc
#   --full:        Run identify only (brainstorming happens in the command, not here)
#
# Workflow:
#   1. LLM calls: --full → gets task context, branch, existing DSN if any
#   2. LLM brainstorms the design (in the command layer)
#   3. LLM calls: --create-doc → gets DSN path + template to fill
#   4. LLM writes the filled DSN to dsn_path using Write tool
#   5. LLM calls: --commit → commits the document

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"

TASK_INPUT=""
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
TASK_BRANCH=""

DSN_PATH=""
DSN_FILENAME=""
EXISTING_DSN=""

# Architecture context (same sources as arch-explore.sh / task-arch-review.sh)
KNOWLEDGE_DOC="docs/architecture/PROJECT-KNOWLEDGE.md"
ADR_DIR="docs/adr"
LANGUAGE_TEMPLATE="${HOME}/.claude/templates/architecture/LANGUAGE.md"
DEEPENING_TEMPLATE="${HOME}/.claude/templates/architecture/DEEPENING.md"
ARCH_CONTEXT_JSON="{}"

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Gather architecture context for the design session. Everything here is
# advisory — a missing file/dir produces empty/null fields, never an error,
# so the design session proceeds while accounting for what's absent.
gather_architecture_context() {
    local knowledge_present="false"
    [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"

    local adr_list_json="[]"
    if [[ -d "$ADR_DIR" ]]; then
        adr_list_json=$(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | sort | jq -R . | jq -sc . 2>/dev/null || echo "[]")
    fi

    local language_present="false" deepening_present="false"
    [[ -f "$LANGUAGE_TEMPLATE" ]] && language_present="true"
    [[ -f "$DEEPENING_TEMPLATE" ]] && deepening_present="true"

    # ARC linkage: /feature-to-task writes a "## Related ARC" section and
    # pre-resolved decisions under "## Notes for /task-design" into the TSK.
    local arc_ref="" arc_present="false" pre_resolved_present="false"
    if [[ -f "${TASK_DOC:-}" ]]; then
        arc_ref=$(grep -oE '[^ `"()]*-ARC-[^ `"()]*\.md' "$TASK_DOC" 2>/dev/null | head -1 || echo "")
        [[ -n "$arc_ref" && -f "$arc_ref" ]] && arc_present="true"
        grep -qE '^##[[:space:]]+Notes for /task-design' "$TASK_DOC" 2>/dev/null && pre_resolved_present="true"
    fi

    ARCH_CONTEXT_JSON=$(jq -nc \
        --arg knowledge_doc "$KNOWLEDGE_DOC" \
        --argjson knowledge_present "$knowledge_present" \
        --arg adr_dir "$ADR_DIR" \
        --argjson adr_files "$adr_list_json" \
        --arg language_template "$LANGUAGE_TEMPLATE" \
        --argjson language_present "$language_present" \
        --arg deepening_template "$DEEPENING_TEMPLATE" \
        --argjson deepening_present "$deepening_present" \
        --arg arc_ref "$arc_ref" \
        --argjson arc_present "$arc_present" \
        --argjson pre_resolved_present "$pre_resolved_present" \
        '{
            knowledge_doc: $knowledge_doc,
            knowledge_present: $knowledge_present,
            adr_dir: $adr_dir,
            adr_files: $adr_files,
            language_template: $language_template,
            language_present: $language_present,
            deepening_template: $deepening_template,
            deepening_present: $deepening_present,
            arc_ref: ($arc_ref | if . == "" then null else . end),
            arc_present: $arc_present,
            pre_resolved_decisions_present: $pre_resolved_present
        }')

    log "${GREEN}✓${NC} Architecture context: ADRs=$(echo "$adr_list_json" | jq -r 'length'), ARC linked=${arc_present}, pre-resolved=${pre_resolved_present}"
}

# Section: Identify task
section_identify() {
    log "${BLUE}Identifying Task${NC}"

    # Priority: explicit --task-id > .current-task > branch detection
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

    if [[ -z "$TASK_BRANCH" ]]; then
        TASK_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi

    log "${GREEN}✓${NC} Task identified: $TASK_ID - $TASK_TITLE"

    # Check if DSN already exists for this task (stored in global for reuse by full mode).
    # Search the current git worktree's docs tree first (TASK_DOC may live in the main
    # repo's docs/, but a DSN created during this session lives in the worktree).
    EXISTING_DSN=""
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_repo_root" && -d "$_repo_root/docs" ]]; then
        EXISTING_DSN=$(find "$_repo_root/docs" -name "${TASK_ID}-*-DSN-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi
    if [[ -z "$EXISTING_DSN" ]]; then
        EXISTING_DSN=$(find "$(dirname "$TASK_DOC")" -name "${TASK_ID}-*-DSN-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi

    # Locate an INV (investigation report) for this task — for investigation-driven
    # tasks it carries the confirmed root cause the design must be grounded in.
    EXISTING_INV=""
    if [[ -n "$_repo_root" && -d "$_repo_root/docs" ]]; then
        EXISTING_INV=$(find "$_repo_root/docs" -name "${TASK_ID}-*-INV-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi
    if [[ -z "$EXISTING_INV" ]]; then
        EXISTING_INV=$(find "$(dirname "$TASK_DOC")" -name "${TASK_ID}-*-INV-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi

    if [[ "$SECTION" == "identify" ]]; then
        local next_act="create_design"
        [[ -n "$EXISTING_DSN" ]] && next_act="resume_design"

        gather_architecture_context

        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg task_doc "$TASK_DOC" \
            --arg task_title "$TASK_TITLE" \
            --arg branch "$TASK_BRANCH" \
            --arg existing_dsn "${EXISTING_DSN:-}" \
            --arg existing_inv "${EXISTING_INV:-}" \
            --arg next_action "$next_act" \
            --argjson architecture "$ARCH_CONTEXT_JSON" \
            '{status:"success", section:"identify", next_action:$next_action, task_id:$task_id, task_doc:$task_doc, task_title:$task_title, branch:$branch, existing_dsn:($existing_dsn | if . == "" then null else . end), existing_inv:($existing_inv | if . == "" then null else . end), architecture:$architecture}')"
        exit 0
    fi
}

# Section: Create DSN document skeleton
section_create_doc() {
    log "${BLUE}Creating Design Document${NC}"

    # Run identify first to populate globals
    section_identify

    # Build a slug from the task title for the doc description
    local desc_slug
    desc_slug=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//' | head -c 40)

    # Call new-doc.sh to get the template and filepath (does NOT write the file)
    local new_doc_output
    new_doc_output=$("${SCRIPT_DIR}/new-doc.sh" \
        --type DSN \
        --description "${desc_slug}" \
        --id "${TASK_ID}" \
        --json 2>/dev/null)

    local dsn_path template
    dsn_path=$(echo "$new_doc_output" | jq -r '.filepath // empty' 2>/dev/null || echo "")
    template=$(echo "$new_doc_output" | jq -r '.template // empty' 2>/dev/null || echo "")

    if [[ -z "$dsn_path" ]]; then
        exit_with_json "error" "new-doc.sh did not return a filepath" "$new_doc_output"
    fi

    DSN_PATH="$dsn_path"
    DSN_FILENAME="$(basename "$dsn_path")"

    log "${GREEN}✓${NC} Prepared: $DSN_FILENAME"

    if [[ "$SECTION" == "create-doc" ]]; then
        log_json "$(jq -nc \
            --arg dsn_path "$DSN_PATH" \
            --arg dsn_filename "$DSN_FILENAME" \
            --arg template "$template" \
            --arg task_id "$TASK_ID" \
            --arg task_title "$TASK_TITLE" \
            '{status:"success", section:"create-doc", next_action:"fill_document", dsn_path:$dsn_path, dsn_filename:$dsn_filename, template:$template, task_id:$task_id, task_title:$task_title, message:"Write the filled DSN to dsn_path using the Write tool, then call --commit"}')"
        exit 0
    fi
}

# Brainstorm checkpoint state file (per-task in project root).
# Lets long design sessions resume after interruption: the LLM records each
# decision as it's made, so a crash/context loss doesn't erase 30 minutes of Q&A.
BRAINSTORM_STATE_FILE=".task-design-state.json"

# Write (or update) the brainstorm state file. Accepts raw JSON as $1.
# Called by the LLM between topic questions to checkpoint its progress.
section_save_state() {
    # Run identify first to set TASK_ID
    section_identify

    if [[ -z "${BRAINSTORM_DECISIONS_JSON:-}" ]]; then
        exit_with_json "error" "No decisions provided" "Pass --decisions '<json-array>' with the accumulated decisions so far"
    fi

    # Validate it's parseable JSON
    if ! echo "$BRAINSTORM_DECISIONS_JSON" | jq empty 2>/dev/null; then
        exit_with_json "error" "Invalid JSON in --decisions" "Must be a JSON array or object"
    fi

    jq -n \
        --arg task_id "$TASK_ID" \
        --arg task_title "$TASK_TITLE" \
        --arg updated "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson decisions "$BRAINSTORM_DECISIONS_JSON" \
        '{task_id: $task_id, task_title: $task_title, updated: $updated, decisions: $decisions}' \
        > "$BRAINSTORM_STATE_FILE"

    log "${GREEN}✓${NC} Brainstorm state saved to $BRAINSTORM_STATE_FILE"

    if [[ "$SECTION" == "save-state" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg file "$BRAINSTORM_STATE_FILE" \
            '{status:"success", section:"save-state", next_action:"display_summary", task_id:$task_id, state_file:$file, message:"Brainstorm state saved — safe to resume after interruption"}')"
        exit 0
    fi
}

# Load the brainstorm state file if it exists for this task.
section_load_state() {
    section_identify

    if [[ ! -f "$BRAINSTORM_STATE_FILE" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            '{status:"success", section:"load-state", next_action:"create_design", task_id:$task_id, state_file:null, decisions:[], message:"No prior brainstorm state — start fresh"}')"
        exit 0
    fi

    # Verify state is for this task
    local state_task_id
    state_task_id=$(jq -r '.task_id // empty' "$BRAINSTORM_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$state_task_id" != "$TASK_ID" ]]; then
        log "${YELLOW}⚠${NC} Brainstorm state file is for task $state_task_id, not $TASK_ID — ignoring"
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg other "$state_task_id" \
            '{status:"success", section:"load-state", next_action:"create_design", task_id:$task_id, state_file:null, decisions:[], warning:("Ignored state from other task: " + $other)}')"
        exit 0
    fi

    log "${GREEN}✓${NC} Loaded brainstorm state from $BRAINSTORM_STATE_FILE"

    log_json "$(jq --arg section "load-state" \
                   --arg next "resume_brainstorm" \
                   '. + {status:"success", section:$section, next_action:$next}' \
                   "$BRAINSTORM_STATE_FILE")"
    exit 0
}

# Section: Commit DSN document
section_commit() {
    log "${BLUE}Committing Design Document${NC}"

    # Run identify first to populate globals
    section_identify

    # Find the DSN doc — should exist by now. Prefer the current git worktree's
    # docs tree so DSNs created in a worktree are found and committable, since
    # git refuses to add files outside the active worktree.
    local dsn_path=""
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_repo_root" && -d "$_repo_root/docs" ]]; then
        dsn_path=$(find "$_repo_root/docs" -name "${TASK_ID}-*-DSN-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi
    if [[ -z "$dsn_path" ]]; then
        dsn_path=$(find "$(dirname "$TASK_DOC")" -name "${TASK_ID}-*-DSN-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi

    if [[ -z "$dsn_path" ]] || [[ ! -f "$dsn_path" ]]; then
        exit_with_json "error" "No DSN document found for task ${TASK_ID}" "Run --create-doc first, fill the template, write it to disk, then call --commit"
    fi

    DSN_PATH="$dsn_path"
    DSN_FILENAME="$(basename "$dsn_path")"

    git add "$DSN_PATH"

    # Stage index files if they exist
    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true
    [[ -f "docs/SEQUENCE-TRACKER.md" ]] && git add "docs/SEQUENCE-TRACKER.md" || true

    # Update doc index if available
    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true

    # Stage updated index again in case update-docs.sh touched it
    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true

    git commit -m "docs(design): create design document for work item ${TASK_ID}

Task: ${TASK_TITLE}
Document: ${DSN_FILENAME}"

    local commit_hash
    commit_hash=$(git rev-parse HEAD)

    log "${GREEN}✓${NC} Committed: $commit_hash"

    # DSN is persisted — brainstorm checkpoint is no longer needed.
    if [[ -f "$BRAINSTORM_STATE_FILE" ]]; then
        rm -f "$BRAINSTORM_STATE_FILE"
        log "${GREEN}✓${NC} Cleared brainstorm state file"
    fi

    if [[ "$SECTION" == "commit" ]]; then
        log_json "$(jq -nc \
            --arg commit_hash "$commit_hash" \
            --arg dsn_path "$DSN_PATH" \
            --arg dsn_filename "$DSN_FILENAME" \
            --arg task_id "$TASK_ID" \
            '{status:"success", section:"commit", next_action:"display_summary", commit_hash:$commit_hash, dsn_path:$dsn_path, dsn_filename:$dsn_filename, task_id:$task_id}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)        OUTPUT_MODE="json"; shift ;;
            --raw)         OUTPUT_MODE="raw"; shift ;;
            --full)        SECTION="full"; shift ;;
            --identify)    SECTION="identify"; shift ;;
            --create-doc)  SECTION="create-doc"; shift ;;
            --commit)      SECTION="commit"; shift ;;
            --save-state)  SECTION="save-state"; shift ;;
            --load-state)  SECTION="load-state"; shift ;;
            --decisions)   BRAINSTORM_DECISIONS_JSON="$2"; shift 2 ;;
            --task-id)     TASK_INPUT="$2"; shift 2 ;;
            *)             echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        identify)
            section_identify
            ;;
        create-doc)
            section_create_doc
            ;;
        commit)
            section_commit
            ;;
        save-state)
            section_save_state
            ;;
        load-state)
            section_load_state
            ;;
        full)
            # Full mode: identify only — brainstorming happens in the command
            section_identify

            # Reuse EXISTING_DSN set by section_identify (no duplicate find)
            local next_act="create_design"
            [[ -n "$EXISTING_DSN" ]] && next_act="resume_design"

            gather_architecture_context

            log_json "$(jq -nc \
                --arg task_id "$TASK_ID" \
                --arg task_title "$TASK_TITLE" \
                --arg task_doc "$TASK_DOC" \
                --arg branch "$TASK_BRANCH" \
                --arg existing_dsn "${EXISTING_DSN:-}" \
                --arg next_action "$next_act" \
                --argjson architecture "$ARCH_CONTEXT_JSON" \
                '{
                    status: "success",
                    next_action: $next_action,
                    task_id: $task_id,
                    task_title: $task_title,
                    task_doc: $task_doc,
                    branch: $branch,
                    existing_dsn: ($existing_dsn | if . == "" then null else . end),
                    architecture: $architecture
                }')"
            exit 0
            ;;
        *)
            exit_with_json "error" "Unknown section: $SECTION" "Valid: identify, create-doc, commit, full"
            ;;
    esac
}

main "$@"

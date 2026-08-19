#!/usr/bin/env bash
set -euo pipefail

# task-research.sh - Create a Research Decision Matrix document (RDM) for a task
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-research.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --identify:    Identify and load task document; report any existing RDM
#   --create-doc:  Create RDM document skeleton via new-doc.sh, return template for LLM to fill
#   --commit:      Stage and commit populated RDM doc
#   --save-state:  Checkpoint research progress (phase + decisions) mid-session
#   --load-state:  Load a prior checkpoint for this task
#   --full:        Run identify only (the 4-phase research happens in the command)
#
# Workflow (the command layer drives the four phases):
#   1. LLM calls: --full            → task context, branch, existing RDM if any
#   2. Phase 1 (goal) + Phase 2 (criteria & scope)  → checkpoint via --save-state
#   3. Phase 3 (research, multi-agent) + Phase 4 (pro/con debate + matrix)
#   4. LLM calls: --create-doc      → RDM path + template to fill
#   5. LLM writes the filled RDM to rdm_path using the Write tool
#   6. LLM calls: --commit          → commits the document

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

RDM_PATH=""
RDM_FILENAME=""
EXISTING_RDM=""

# Advisory context (same sources as task-design.sh) — a missing file is never
# an error; it just produces empty/null fields so the session still proceeds.
KNOWLEDGE_DOC="docs/architecture/PROJECT-KNOWLEDGE.md"

# Populated by section_identify via detect_grounding(); reused by every output.
GROUNDING_JSON="{}"

# Detect available "current-state" grounding sources so Phase 0 collects REAL
# evidence about where-we-are instead of the research assuming or guessing.
# Returns a JSON object; presence is a hint, the LLM decides relevance.
detect_grounding() {
    local pc_script="${HOME}/.claude/scripts/project-context.sh"
    local pc_cmd=""
    [[ -x "$pc_script" ]] && pc_cmd="$pc_script --json --full"

    local understand_graph="false"
    [[ -f ".understand/graph.json" ]] && understand_graph="true"

    local project_yaml="false"
    [[ -f "PROJECT.yaml" ]] && project_yaml="true"

    # Infra/data CLIs whose presence hints the decision may need a LIVE
    # inventory of the running system (accounts, clusters, DBs, resources).
    local found=()
    local c
    for c in aws gcloud az kubectl terraform tofu psql mysql redis-cli gh glab docker; do
        command -v "$c" >/dev/null 2>&1 && found+=("$c")
    done
    local clis_json="[]"
    if [[ ${#found[@]} -gt 0 ]]; then
        clis_json=$(printf '%s\n' "${found[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')
    fi

    jq -nc \
        --arg pc "$pc_cmd" \
        --argjson ug "$understand_graph" \
        --argjson py "$project_yaml" \
        --argjson clis "$clis_json" \
        '{project_context:($pc | if .=="" then null else . end), understand_graph:$ug, project_yaml:$py, infra_clis:$clis}'
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

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

    # Check if an RDM already exists for this task. Search the current git
    # worktree's docs tree first (an RDM created this session lives there),
    # then fall back to the task doc's own directory.
    EXISTING_RDM=""
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_repo_root" && -d "$_repo_root/docs" ]]; then
        EXISTING_RDM=$(find "$_repo_root/docs" -name "${TASK_ID}-*-RDM-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi
    if [[ -z "$EXISTING_RDM" ]]; then
        EXISTING_RDM=$(find "$(dirname "$TASK_DOC")" -name "${TASK_ID}-*-RDM-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi

    local knowledge_present="false"
    [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"

    GROUNDING_JSON="$(detect_grounding)"

    if [[ "$SECTION" == "identify" ]]; then
        local next_act="create_research"
        [[ -n "$EXISTING_RDM" ]] && next_act="resume_research"

        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg task_doc "$TASK_DOC" \
            --arg task_title "$TASK_TITLE" \
            --arg branch "$TASK_BRANCH" \
            --arg existing_rdm "${EXISTING_RDM:-}" \
            --arg knowledge_doc "$KNOWLEDGE_DOC" \
            --argjson knowledge_present "$knowledge_present" \
            --argjson grounding "$GROUNDING_JSON" \
            --arg next_action "$next_act" \
            '{status:"success", section:"identify", next_action:$next_action, task_id:$task_id, task_doc:$task_doc, task_title:$task_title, branch:$branch, existing_rdm:($existing_rdm | if . == "" then null else . end), knowledge_doc:$knowledge_doc, knowledge_present:$knowledge_present, grounding:$grounding, current_state_required:true, current_state_hint:"Before Phase 1, run Phase 0: collect ground-truth current state from the grounding sources (project_context, understand_graph, PROJECT.yaml) and, where the decision touches live infra/data, the relevant infra_clis. Do NOT assume or guess system facts — capture them; mark anything you cannot confirm as an explicit open question to verify, never a guess."}')"
        exit 0
    fi
}

# Section: Create RDM document skeleton
section_create_doc() {
    log "${BLUE}Creating Research Decision Matrix Document${NC}"

    # Run identify first to populate globals
    section_identify

    # Build a slug from the task title for the doc description
    local desc_slug
    desc_slug=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//' | head -c 40)

    # Call new-doc.sh to get the template and filepath (does NOT write the file)
    local new_doc_output
    new_doc_output=$("${SCRIPT_DIR}/new-doc.sh" \
        --type RDM \
        --description "${desc_slug}" \
        --id "${TASK_ID}" \
        --json 2>/dev/null)

    local rdm_path template
    rdm_path=$(echo "$new_doc_output" | jq -r '.filepath // empty' 2>/dev/null || echo "")
    template=$(echo "$new_doc_output" | jq -r '.template // empty' 2>/dev/null || echo "")

    if [[ -z "$rdm_path" ]]; then
        exit_with_json "error" "new-doc.sh did not return a filepath" "$new_doc_output"
    fi

    RDM_PATH="$rdm_path"
    RDM_FILENAME="$(basename "$rdm_path")"

    log "${GREEN}✓${NC} Prepared: $RDM_FILENAME"

    if [[ "$SECTION" == "create-doc" ]]; then
        log_json "$(jq -nc \
            --arg rdm_path "$RDM_PATH" \
            --arg rdm_filename "$RDM_FILENAME" \
            --arg template "$template" \
            --arg task_id "$TASK_ID" \
            --arg task_title "$TASK_TITLE" \
            '{status:"success", section:"create-doc", next_action:"fill_document", rdm_path:$rdm_path, rdm_filename:$rdm_filename, template:$template, task_id:$task_id, task_title:$task_title, message:"Write the filled RDM to rdm_path using the Write tool, then call --commit"}')"
        exit 0
    fi
}

# Research checkpoint state file (per-task in project root). Lets a long
# 4-phase research session resume after interruption: the LLM records the
# current phase + accumulated decisions, so a crash/context loss doesn't
# erase the goal, criteria, and research already gathered.
RESEARCH_STATE_FILE=".task-research-state.json"

# Write (or update) the research state file. Accepts raw JSON via --decisions
# and a phase label via --phase.
section_save_state() {
    section_identify

    if [[ -z "${RESEARCH_DECISIONS_JSON:-}" ]]; then
        exit_with_json "error" "No state provided" "Pass --decisions '<json>' with the accumulated goal/criteria/research so far"
    fi

    if ! echo "$RESEARCH_DECISIONS_JSON" | jq empty 2>/dev/null; then
        exit_with_json "error" "Invalid JSON in --decisions" "Must be a JSON array or object"
    fi

    jq -n \
        --arg task_id "$TASK_ID" \
        --arg task_title "$TASK_TITLE" \
        --arg phase "${RESEARCH_PHASE:-unknown}" \
        --arg updated "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson decisions "$RESEARCH_DECISIONS_JSON" \
        '{task_id: $task_id, task_title: $task_title, phase: $phase, updated: $updated, decisions: $decisions}' \
        > "$RESEARCH_STATE_FILE"

    log "${GREEN}✓${NC} Research state saved to $RESEARCH_STATE_FILE (phase: ${RESEARCH_PHASE:-unknown})"

    if [[ "$SECTION" == "save-state" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg file "$RESEARCH_STATE_FILE" \
            --arg phase "${RESEARCH_PHASE:-unknown}" \
            '{status:"success", section:"save-state", next_action:"continue_research", task_id:$task_id, state_file:$file, phase:$phase, message:"Research state saved — safe to resume after interruption"}')"
        exit 0
    fi
}

# Load the research state file if it exists for this task.
section_load_state() {
    section_identify

    if [[ ! -f "$RESEARCH_STATE_FILE" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            '{status:"success", section:"load-state", next_action:"create_research", task_id:$task_id, state_file:null, phase:null, decisions:[], message:"No prior research state — start fresh at Phase 1"}')"
        exit 0
    fi

    local state_task_id
    state_task_id=$(jq -r '.task_id // empty' "$RESEARCH_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$state_task_id" != "$TASK_ID" ]]; then
        log "${YELLOW}⚠${NC} Research state file is for task $state_task_id, not $TASK_ID — ignoring"
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" \
            --arg other "$state_task_id" \
            '{status:"success", section:"load-state", next_action:"create_research", task_id:$task_id, state_file:null, phase:null, decisions:[], warning:("Ignored state from other task: " + $other)}')"
        exit 0
    fi

    log "${GREEN}✓${NC} Loaded research state from $RESEARCH_STATE_FILE"

    log_json "$(jq --arg section "load-state" \
                   --arg next "resume_research" \
                   '. + {status:"success", section:$section, next_action:$next}' \
                   "$RESEARCH_STATE_FILE")"
    exit 0
}

# Section: Commit RDM document
section_commit() {
    log "${BLUE}Committing Research Decision Matrix Document${NC}"

    section_identify

    # Find the RDM doc — should exist by now. Prefer the current git worktree's
    # docs tree so RDMs created in a worktree are found and committable.
    local rdm_path=""
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_repo_root" && -d "$_repo_root/docs" ]]; then
        rdm_path=$(find "$_repo_root/docs" -name "${TASK_ID}-*-RDM-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi
    if [[ -z "$rdm_path" ]]; then
        rdm_path=$(find "$(dirname "$TASK_DOC")" -name "${TASK_ID}-*-RDM-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi

    if [[ -z "$rdm_path" ]] || [[ ! -f "$rdm_path" ]]; then
        exit_with_json "error" "No RDM document found for task ${TASK_ID}" "Run --create-doc first, fill the template, write it to disk, then call --commit"
    fi

    RDM_PATH="$rdm_path"
    RDM_FILENAME="$(basename "$rdm_path")"

    git add "$RDM_PATH"

    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true
    [[ -f "docs/SEQUENCE-TRACKER.md" ]] && git add "docs/SEQUENCE-TRACKER.md" || true

    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true

    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true

    git commit -m "docs(research): create research decision matrix for work item ${TASK_ID}

Task: ${TASK_TITLE}
Document: ${RDM_FILENAME}"

    local commit_hash
    commit_hash=$(git rev-parse HEAD)

    log "${GREEN}✓${NC} Committed: $commit_hash"

    # RDM is persisted — research checkpoint is no longer needed.
    if [[ -f "$RESEARCH_STATE_FILE" ]]; then
        rm -f "$RESEARCH_STATE_FILE"
        log "${GREEN}✓${NC} Cleared research state file"
    fi

    if [[ "$SECTION" == "commit" ]]; then
        log_json "$(jq -nc \
            --arg commit_hash "$commit_hash" \
            --arg rdm_path "$RDM_PATH" \
            --arg rdm_filename "$RDM_FILENAME" \
            --arg task_id "$TASK_ID" \
            '{status:"success", section:"commit", next_action:"display_summary", commit_hash:$commit_hash, rdm_path:$rdm_path, rdm_filename:$rdm_filename, task_id:$task_id}')"
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
            --decisions)   RESEARCH_DECISIONS_JSON="$2"; shift 2 ;;
            --phase)       RESEARCH_PHASE="$2"; shift 2 ;;
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
            # Full mode: identify only — the 4-phase research happens in the command
            section_identify

            local next_act="create_research"
            [[ -n "$EXISTING_RDM" ]] && next_act="resume_research"

            local knowledge_present="false"
            [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"

            log_json "$(jq -nc \
                --arg task_id "$TASK_ID" \
                --arg task_title "$TASK_TITLE" \
                --arg task_doc "$TASK_DOC" \
                --arg branch "$TASK_BRANCH" \
                --arg existing_rdm "${EXISTING_RDM:-}" \
                --arg knowledge_doc "$KNOWLEDGE_DOC" \
                --argjson knowledge_present "$knowledge_present" \
                --argjson grounding "$GROUNDING_JSON" \
                --arg next_action "$next_act" \
                '{
                    status: "success",
                    next_action: $next_action,
                    task_id: $task_id,
                    task_title: $task_title,
                    task_doc: $task_doc,
                    branch: $branch,
                    existing_rdm: ($existing_rdm | if . == "" then null else . end),
                    knowledge_doc: $knowledge_doc,
                    knowledge_present: $knowledge_present,
                    grounding: $grounding,
                    current_state_required: true,
                    current_state_hint: "Before Phase 1, run Phase 0: collect ground-truth current state from the grounding sources (project_context, understand_graph, PROJECT.yaml) and, where the decision touches live infra/data, the relevant infra_clis. Do NOT assume or guess system facts — capture them; mark anything you cannot confirm as an explicit open question to verify, never a guess."
                }')"
            exit 0
            ;;
        *)
            exit_with_json "error" "Unknown section: $SECTION" "Valid: identify, create-doc, commit, save-state, load-state, full"
            ;;
    esac
}

main "$@"

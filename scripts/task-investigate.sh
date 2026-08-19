#!/usr/bin/env bash
# task-investigate.sh - Gather context for a rigorous root-cause investigation of the current task
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes.
#
# This is a "smart script, simple command" context-gatherer. It does NOT perform
# the investigation itself — investigating (reading code, tracing call chains,
# and, when appropriate, probing production servers) is inherently LLM-driven and
# project-specific. The script deterministically loads the task, extracts the
# problem statement + any existing hypothesis, surfaces candidate code references,
# reports what production-access the project documents, resolves an FND document
# path/template, and hands off to the LLM with next_action=investigate.
#
# Usage:
#   ~/.claude/scripts/task-investigate.sh [--json|--raw|--toon] [--full|--section] [--task-id ID]
#
# Output Modes:
#   --json: Structured output for LLM (default; TOON auto for LLM callers)
#   --raw:  Verbose debugging output
#
# Section Flags:
#   --load:     Load + validate the task only
#   --context:  Gather investigation context only (implies --load)
#   --full:     Load + gather context + hand off (default)

set -euo pipefail

OUTPUT_MODE="json"
SECTION="full"
TASK_ID_ARG=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Task data
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""

# Investigation context
IS_INVESTIGATION_DRIVEN=false
PROBLEM_STATEMENT=""
EXISTING_HYPOTHESIS=""
CODE_REFERENCES=""      # newline-separated file:line refs mined from the TSK
CHANGED_FILES=""        # branch diff (usually empty for a fresh investigation)
PROD_ACCESS_DOCUMENTED=false
PROD_ACCESS_SOURCE=""
DEPLOY_ENVS=""

#------------------------------------------------------------------------------
# Section 1: Load Task
#------------------------------------------------------------------------------

section_load() {
    log "${BLUE}Loading task${NC}"

    if [[ -z "$TASK_ID_ARG" ]] && load_current_task; then
        TASK_ID="$CT_TASK_ID"
        CURRENT_BRANCH="$CT_BRANCH"
        log "${GREEN}Current task: $TASK_ID (branch: $CURRENT_BRANCH)${NC}"
    elif [[ -n "$TASK_ID_ARG" ]]; then
        if [[ "$TASK_ID_ARG" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$TASK_ID_ARG")
        else
            exit_with_json "error" "Invalid task ID: $TASK_ID_ARG"
        fi
    else
        exit_with_json "error" "No task specified and no .current-task file" \
            "Run from a started task, or pass --task-id"
    fi

    TASK_DOC=$(find_primary "$TASK_ID")
    if [[ -z "$TASK_DOC" ]] || [[ ! -f "$TASK_DOC" ]]; then
        exit_with_json "error" "Task document not found for task ID $TASK_ID"
    fi

    TASK_TITLE=$(get_doc_title "$TASK_DOC")
    CURRENT_BRANCH=${CURRENT_BRANCH:-$(git branch --show-current 2>/dev/null || echo "")}
    DEFAULT_BRANCH=$(get_default_branch_interactive 2>/dev/null || echo "main")

    log "${BLUE}Investigating: $TASK_TITLE${NC}"
    log "${BLUE}Task ID: $TASK_ID${NC}"

    if [[ "$SECTION" == "load" ]]; then
        exit_with_json "success" "Task loaded" "" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_title\": $(printf '%s' "$TASK_TITLE" | jq -Rs .)," \
            "\"task_doc\": $(printf '%s' "$TASK_DOC" | jq -Rs .)," \
            "\"branch\": \"$CURRENT_BRANCH\""
    fi

    log "${GREEN}✓${NC} Task loaded"
}

#------------------------------------------------------------------------------
# Section 2: Gather Investigation Context
#------------------------------------------------------------------------------

section_context() {
    log "${BLUE}Gathering investigation context${NC}"

    # Investigation-driven marker written by /task-capture
    if grep -qiE 'Investigation pending|Leading hypothesis|investigation-driven' "$TASK_DOC" 2>/dev/null; then
        IS_INVESTIGATION_DRIVEN=true
    fi

    # Problem statement: the Summary section body
    PROBLEM_STATEMENT=$(awk '/^## Summary/{f=1; next} /^## /{f=0} f' "$TASK_DOC" 2>/dev/null \
        | grep -v '^[[:space:]]*$' | head -8 || echo "")

    # Existing hypothesis: the Research Findings section body (if present)
    EXISTING_HYPOTHESIS=$(awk '/^## Research Findings/{f=1; next} /^## /{f=0} f' "$TASK_DOC" 2>/dev/null \
        | grep -v '^[[:space:]]*$' | head -20 || echo "")

    # Candidate code references: file:line tokens mentioned anywhere in the TSK
    CODE_REFERENCES=$(grep -oE '[A-Za-z0-9_./-]+\.(ts|tsx|js|jsx|py|go|java|rb|php|rs|sh)(:[0-9]+)?' "$TASK_DOC" 2>/dev/null \
        | sort -u | head -40 || echo "")

    # Branch diff (usually empty for a fresh investigation — but surface it if code changed)
    if [[ -n "$CURRENT_BRANCH" ]] && [[ -n "$DEFAULT_BRANCH" ]]; then
        CHANGED_FILES=$(git diff --name-only "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | head -50 || echo "")
    fi

    # Production access: is it documented for this project? The script never
    # invents prod endpoints/credentials — it only reports where the LLM should
    # look. Project CLAUDE.md is the source of truth for how to reach prod.
    if [[ -f "CLAUDE.md" ]] && grep -qiE 'production|prod|SSM|RDS|health/|Secrets Manager|ssh ' CLAUDE.md 2>/dev/null; then
        PROD_ACCESS_DOCUMENTED=true
        PROD_ACCESS_SOURCE="CLAUDE.md"
    fi

    if [[ -f "PROJECT.yaml" ]]; then
        DEPLOY_ENVS=$(yaml_get '.deployment | keys | .[]' PROJECT.yaml 2>/dev/null \
            | grep -vE '^(active|version_path|strategy)$' | tr '\n' ' ' || echo "")
        if [[ -n "$DEPLOY_ENVS" ]] && [[ "$PROD_ACCESS_DOCUMENTED" == "false" ]]; then
            PROD_ACCESS_DOCUMENTED=true
            PROD_ACCESS_SOURCE="PROJECT.yaml (deployment block)"
        fi
    fi

    log "  Investigation-driven: $IS_INVESTIGATION_DRIVEN"
    log "  Code references found: $(echo "$CODE_REFERENCES" | grep -c . || echo 0)"
    log "  Production access documented: $PROD_ACCESS_DOCUMENTED"

    if [[ "$SECTION" == "context" ]]; then
        emit_handoff
    fi

    log "${GREEN}✓${NC} Context gathered"
}

#------------------------------------------------------------------------------
# Emit the investigation handoff payload
#------------------------------------------------------------------------------

emit_handoff() {
    # Resolve INV (investigation report) document path + template (dry run — no file written)
    local inv_filepath="" inv_template="" inv_doc_json=""
    inv_doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type INV --description "investigation" --id "$TASK_ID" --json 2>/dev/null || true)
    if [[ -n "$inv_doc_json" ]]; then
        inv_filepath=$(echo "$inv_doc_json" | jq -r '.filepath // empty')
        inv_template=$(echo "$inv_doc_json" | jq -r '.template // empty')
    fi

    local code_refs_json="[]"
    [[ -n "$CODE_REFERENCES" ]] && code_refs_json=$(echo "$CODE_REFERENCES" | jq -R . | jq -s .)

    local changed_files_json="[]"
    [[ -n "$CHANGED_FILES" ]] && changed_files_json=$(echo "$CHANGED_FILES" | jq -R . | jq -s .)

    local json
    json=$(cat <<EOF
{
  "status": "ready_for_opus",
  "next_action": "investigate",
  "section": "$SECTION",
  "message": "Investigation context gathered — LLM must now truly investigate the root cause",
  "task_id": "$TASK_ID",
  "task_title": $(printf '%s' "$TASK_TITLE" | jq -Rs .),
  "task_doc": $(printf '%s' "$TASK_DOC" | jq -Rs .),
  "branch": "$CURRENT_BRANCH",
  "is_investigation_driven": $IS_INVESTIGATION_DRIVEN,
  "problem_statement": $(printf '%s' "$PROBLEM_STATEMENT" | jq -Rs .),
  "existing_hypothesis": $(printf '%s' "$EXISTING_HYPOTHESIS" | jq -Rs .),
  "code_references": $code_refs_json,
  "changed_files": $changed_files_json,
  "production_access": {
    "documented": $PROD_ACCESS_DOCUMENTED,
    "source": $(printf '%s' "$PROD_ACCESS_SOURCE" | jq -Rs .),
    "deploy_envs": $(printf '%s' "$DEPLOY_ENVS" | jq -Rs .)
  },
  "inv_filepath": $(printf '%s' "$inv_filepath" | jq -Rs .),
  "inv_template": $(echo "$inv_template" | jq -Rs .),
  "investigation_protocol": [
    "Reproduce/trace from the reported symptom — read the actual code paths, do not assume",
    "Follow each candidate code reference and the call chain around it to confirm or kill the hypothesis",
    "Only when the code alone cannot settle it, and prod access is documented, probe production per the project CLAUDE.md (health endpoints, SSM, read-only DB queries) — read-only, PHI-safe, never guess credentials",
    "Classify every conclusion: CONFIRMED (direct code/data/prod evidence) vs THEORY (plausible, unproven) — label which and state what evidence is still missing",
    "Finding no defect is a VALID outcome — say so plainly rather than inventing a cause",
    "Write the investigation report to inv_filepath using inv_template (INV doc); then update the TSK Research Findings section with the dated result"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
    log_json "$json"
    exit 0
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --load|--identify) SECTION="load"; shift ;;
            --context) SECTION="context"; shift ;;
            --full) SECTION="full"; shift ;;
            --task-id) TASK_ID_ARG="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        load)
            section_load
            ;;
        context)
            section_load
            section_context
            ;;
        full)
            section_load
            section_context
            emit_handoff
            ;;
    esac
}

main "$@"

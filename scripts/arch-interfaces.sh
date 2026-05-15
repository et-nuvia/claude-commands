#!/usr/bin/env bash
set -euo pipefail

# arch-interfaces.sh - Parallel sub-agent interface design for a deepening candidate
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/arch-interfaces.sh [--json|--raw] [--full|--section] [--arc-doc <path>]
#
# Sections:
#   --identify:  Locate ARC doc, return body
#   --commit:    Stage + commit ARC doc updates (Interface Alternatives + Recommendation)
#   --full:      Run identify
#
# Workflow:
#   1. LLM calls --full → gets ARC body + path
#   2. LLM frames problem space, spawns 3+ parallel Agent sub-agents w/ divergent constraints
#   3. LLM compares results, writes opinionated recommendation
#   4. LLM Edits ARC doc to fill Interface Alternatives + Recommendation
#   5. LLM calls --commit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        ready_for_opus)       echo "use_opus_model" ;;
        ready_for_fanout)     echo "spawn_parallel_subagents" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/doc-utils.sh"

OUTPUT_MODE="json"
SECTION="full"
ARC_DOC=""

LANGUAGE_TEMPLATE="${HOME}/.claude/templates/architecture/LANGUAGE.md"
DEEPENING_TEMPLATE="${HOME}/.claude/templates/architecture/DEEPENING.md"
INTERFACE_TEMPLATE="${HOME}/.claude/templates/architecture/INTERFACE-DESIGN.md"
KNOWLEDGE_DOC="docs/architecture/PROJECT-KNOWLEDGE.md"

ARC_TASK_ID=""
ARC_FILENAME=""

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

resolve_arc_doc() {
    if [[ -n "$ARC_DOC" ]]; then
        if [[ ! -f "$ARC_DOC" ]]; then
            exit_with_json "error" "ARC doc not found: $ARC_DOC" "Pass --arc-doc <path> or omit to use newest active ARC"
        fi
        return 0
    fi

    ARC_DOC=$(find docs/active -name "*-ARC-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    if [[ -z "$ARC_DOC" ]]; then
        exit_with_json "error" "No ARC document found under docs/active" "Run /arch-explore + /arch-grill first"
    fi
}

#------------------------------------------------------------------------------
# Section: Identify
#------------------------------------------------------------------------------

section_identify() {
    log "${BLUE}Identifying ARC Document${NC}"

    resolve_arc_doc

    ARC_FILENAME="$(basename "$ARC_DOC")"
    ARC_TASK_ID=$(get_task_id "$ARC_FILENAME")

    log "${GREEN}✓${NC} ARC: $ARC_FILENAME ($ARC_TASK_ID)"

    local body
    body=$(cat "$ARC_DOC")

    # Was the Grilled Design section populated? Cheap heuristic.
    local has_grilled="false"
    if grep -q "^### Candidate" "$ARC_DOC" 2>/dev/null; then
        has_grilled="true"
    fi

    local knowledge_present="false"
    [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"

    log_json "$(jq -nc \
        --arg arc_doc "$ARC_DOC" \
        --arg arc_filename "$ARC_FILENAME" \
        --arg task_id "$ARC_TASK_ID" \
        --arg body "$body" \
        --argjson has_grilled "$has_grilled" \
        --arg language_template "$LANGUAGE_TEMPLATE" \
        --arg deepening_template "$DEEPENING_TEMPLATE" \
        --arg interface_template "$INTERFACE_TEMPLATE" \
        --arg knowledge_doc "$KNOWLEDGE_DOC" \
        --argjson knowledge_present "$knowledge_present" \
        '{
            status: "success",
            section: "identify",
            next_action: "spawn_parallel_subagents",
            arc_doc: $arc_doc,
            arc_filename: $arc_filename,
            task_id: $task_id,
            arc_body: $body,
            has_grilled: $has_grilled,
            language_template: $language_template,
            deepening_template: $deepening_template,
            interface_template: $interface_template,
            knowledge_doc: $knowledge_doc,
            knowledge_present: $knowledge_present
        }')"
    exit 0
}

#------------------------------------------------------------------------------
# Section: Commit
#------------------------------------------------------------------------------

section_commit() {
    resolve_arc_doc
    ARC_FILENAME="$(basename "$ARC_DOC")"
    ARC_TASK_ID=$(get_task_id "$ARC_FILENAME")

    git add "$ARC_DOC"
    [[ -f "$KNOWLEDGE_DOC" ]] && git add "$KNOWLEDGE_DOC" 2>/dev/null || true

    if git diff --cached --quiet; then
        exit_with_json "error" "No changes to commit" "Edit ARC doc w/ Interface Alternatives + Recommendation first"
    fi

    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true

    git commit -m "docs(arch): interface alternatives + recommendation ${ARC_TASK_ID}

Document: ${ARC_FILENAME}
Source: /arch-interfaces" >/dev/null

    local commit_hash
    commit_hash=$(git rev-parse HEAD)

    log "${GREEN}✓${NC} Committed: $commit_hash"

    log_json "$(jq -nc \
        --arg commit_hash "$commit_hash" \
        --arg arc_doc "$ARC_DOC" \
        --arg task_id "$ARC_TASK_ID" \
        '{
            status: "success",
            section: "commit",
            next_action: "display_summary",
            commit_hash: $commit_hash,
            arc_doc: $arc_doc,
            task_id: $task_id,
            next_command: "/feature-to-task"
        }')"
    exit 0
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)      OUTPUT_MODE="json"; shift ;;
            --raw)       OUTPUT_MODE="raw"; shift ;;
            --full)      SECTION="full"; shift ;;
            --identify)  SECTION="identify"; shift ;;
            --commit)    SECTION="commit"; shift ;;
            --arc-doc)   ARC_DOC="$2"; shift 2 ;;
            *)           echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        identify|full) section_identify ;;
        commit)        section_commit ;;
        *)             exit_with_json "error" "Unknown section: $SECTION" "Valid: identify, commit, full" ;;
    esac
}

main "$@"

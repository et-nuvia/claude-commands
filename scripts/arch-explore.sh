#!/usr/bin/env bash
set -euo pipefail

# arch-explore.sh - Discover architectural deepening candidates across a codebase
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/arch-explore.sh [--json|--raw] [--full|--section] [--description <slug>]
#
# Sections:
#   --check:       Detect PROJECT-KNOWLEDGE.md, ADR dir, git repo state
#   --create-doc:  Create ARC document skeleton via new-doc.sh
#   --commit:      Stage + commit populated ARC doc
#   --full:        Run check (LLM does exploration + writes doc + calls commit)
#
# Workflow:
#   1. LLM calls --full → gets repo context, knowledge doc path, ADR list
#   2. LLM spawns Explore subagent to walk codebase using LANGUAGE.md heuristics
#   3. LLM calls --create-doc → gets ARC path + template
#   4. LLM fills template w/ numbered candidates, writes to arc_path
#   5. LLM calls --commit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        ready_for_opus)       echo "use_opus_model" ;;
        ready_for_explore)    echo "spawn_explore_subagent" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/doc-utils.sh"

OUTPUT_MODE="json"
SECTION="full"
DESCRIPTION=""

KNOWLEDGE_DOC="docs/architecture/PROJECT-KNOWLEDGE.md"
ADR_DIR="docs/adr"
LANGUAGE_TEMPLATE="${HOME}/.claude/templates/architecture/LANGUAGE.md"
DEEPENING_TEMPLATE="${HOME}/.claude/templates/architecture/DEEPENING.md"

ARC_PATH=""
ARC_FILENAME=""
ARC_TASK_ID=""

#------------------------------------------------------------------------------
# Section: Check preconditions + gather context
#------------------------------------------------------------------------------

section_check() {
    log "${BLUE}Checking Architecture Context${NC}"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        exit_with_json "error" "Not in a git repository" "Run from a project root with git initialized"
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    local knowledge_present="false"
    [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"

    local adr_list_json="[]"
    if [[ -d "$ADR_DIR" ]]; then
        adr_list_json=$(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | sort \
            | jq -R . \
            | jq -sc . 2>/dev/null || echo "[]")
    fi

    log "${GREEN}✓${NC} Branch: $branch"
    log "${GREEN}✓${NC} PROJECT-KNOWLEDGE.md present: $knowledge_present"
    log "${GREEN}✓${NC} ADR files: $(echo "$adr_list_json" | jq -r 'length')"

    if [[ "$SECTION" == "check" || "$SECTION" == "full" ]]; then
        log_json "$(jq -nc \
            --arg branch "$branch" \
            --arg knowledge_doc "$KNOWLEDGE_DOC" \
            --argjson knowledge_present "$knowledge_present" \
            --arg adr_dir "$ADR_DIR" \
            --argjson adr_files "$adr_list_json" \
            --arg language_template "$LANGUAGE_TEMPLATE" \
            --arg deepening_template "$DEEPENING_TEMPLATE" \
            '{
                status: "success",
                section: "check",
                next_action: "spawn_explore_subagent",
                branch: $branch,
                knowledge_doc: $knowledge_doc,
                knowledge_present: $knowledge_present,
                adr_dir: $adr_dir,
                adr_files: $adr_files,
                language_template: $language_template,
                deepening_template: $deepening_template
            }')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Create ARC document skeleton
#------------------------------------------------------------------------------

section_create_doc() {
    log "${BLUE}Creating ARC Document${NC}"

    if [[ -z "$DESCRIPTION" ]]; then
        DESCRIPTION="deepening-candidates"
    fi

    # Normalize description to kebab-case
    DESCRIPTION=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//' | head -c 50)

    # new-doc.sh requires docs/ to exist
    mkdir -p docs/active

    local new_doc_output
    new_doc_output=$("${SCRIPT_DIR}/new-doc.sh" \
        --type ARC \
        --description "$DESCRIPTION" \
        --new \
        --json 2>/dev/null)

    local filepath template task_id
    filepath=$(echo "$new_doc_output" | jq -r '.filepath // empty' 2>/dev/null || echo "")
    template=$(echo "$new_doc_output" | jq -r '.template // empty' 2>/dev/null || echo "")
    task_id=$(echo "$new_doc_output" | jq -r '.task_id // empty' 2>/dev/null || echo "")

    if [[ -z "$filepath" ]]; then
        exit_with_json "error" "new-doc.sh did not return a filepath" "$new_doc_output"
    fi

    ARC_PATH="$filepath"
    ARC_FILENAME="$(basename "$filepath")"
    ARC_TASK_ID="$task_id"

    log "${GREEN}✓${NC} Prepared: $ARC_FILENAME"

    if [[ "$SECTION" == "create-doc" ]]; then
        log_json "$(jq -nc \
            --arg arc_path "$ARC_PATH" \
            --arg arc_filename "$ARC_FILENAME" \
            --arg task_id "$ARC_TASK_ID" \
            --arg template "$template" \
            '{
                status: "success",
                section: "create-doc",
                next_action: "fill_document",
                arc_path: $arc_path,
                arc_filename: $arc_filename,
                task_id: $task_id,
                template: $template,
                message: "Write the filled ARC doc to arc_path using the Write tool, then call --commit"
            }')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Commit ARC document
#------------------------------------------------------------------------------

section_commit() {
    log "${BLUE}Committing ARC Document${NC}"

    # Find newest ARC doc if not passed via env
    local arc_path
    arc_path=$(find docs/active -name "*-ARC-*.md" 2>/dev/null | sort -r | head -1 || echo "")

    if [[ -z "$arc_path" ]] || [[ ! -f "$arc_path" ]]; then
        exit_with_json "error" "No ARC document found under docs/active" "Run --create-doc first, fill the template, then call --commit"
    fi

    ARC_PATH="$arc_path"
    ARC_FILENAME="$(basename "$arc_path")"
    ARC_TASK_ID=$(get_task_id "$ARC_FILENAME")

    git add "$ARC_PATH"

    if git diff --cached --quiet; then
        exit_with_json "error" "No ARC doc changes staged" "Fill the template at $ARC_PATH before committing"
    fi

    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true
    [[ -f "docs/SEQUENCE-TRACKER.md" ]] && git add "docs/SEQUENCE-TRACKER.md" || true

    git commit -m "docs(arch): record deepening candidates ${ARC_TASK_ID}

Document: ${ARC_FILENAME}
Source: /arch-explore" >/dev/null

    local commit_hash
    commit_hash=$(git rev-parse HEAD)

    log "${GREEN}✓${NC} Committed: $commit_hash"

    if [[ "$SECTION" == "commit" ]]; then
        log_json "$(jq -nc \
            --arg commit_hash "$commit_hash" \
            --arg arc_path "$ARC_PATH" \
            --arg arc_filename "$ARC_FILENAME" \
            --arg task_id "$ARC_TASK_ID" \
            '{
                status: "success",
                section: "commit",
                next_action: "display_summary",
                commit_hash: $commit_hash,
                arc_path: $arc_path,
                arc_filename: $arc_filename,
                task_id: $task_id,
                next_command: "/arch-grill"
            }')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)         OUTPUT_MODE="json"; shift ;;
            --raw)          OUTPUT_MODE="raw"; shift ;;
            --full)         SECTION="full"; shift ;;
            --check)        SECTION="check"; shift ;;
            --create-doc)   SECTION="create-doc"; shift ;;
            --commit)       SECTION="commit"; shift ;;
            --description)  DESCRIPTION="$2"; shift 2 ;;
            *)              echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        check)         section_check ;;
        create-doc)    section_create_doc ;;
        commit)        section_commit ;;
        full)          section_check ;;
        *)             exit_with_json "error" "Unknown section: $SECTION" "Valid: check, create-doc, commit, full" ;;
    esac
}

main "$@"

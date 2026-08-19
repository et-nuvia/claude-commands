#!/usr/bin/env bash
set -euo pipefail

# arch-grill.sh - Grilling loop: deep-dive a chosen deepening candidate
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/arch-grill.sh [--json|--raw] [--full|--section]
#                                   [--arc-doc <path>] [--candidate <#>]
#                                   [--decisions '<json>']
#                                   [--slug <adr-slug>] [--reason '<load-bearing reason>']
#
# Sections:
#   --identify:    Locate ARC doc, return body + parsed candidates
#   --save-state:  Checkpoint grilling decisions to .arch-grill-state.json
#   --load-state:  Load checkpoint if present
#   --write-adr:   Create docs/adr/NNNN-<slug>.md from template
#   --commit:      Stage + commit ARC update (and ADR if written)
#   --full:        Run identify
#
# Workflow:
#   1. LLM calls --full → gets ARC body + candidate list
#   2. LLM grills the chosen candidate w/ user (conversational)
#   3. LLM may call --save-state between topics
#   4. If user rejects w/ load-bearing reason: LLM calls --write-adr
#   5. LLM Edits ARC doc to fill Grilled Design section (new domain terms are
#      parked there as proposed terms — PROJECT-KNOWLEDGE.md is current-state
#      only and gets updated by /task-close when the work lands)
#   6. LLM calls --commit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        ready_for_opus)       echo "use_opus_model" ;;
        ready_for_grill)      echo "run_grilling_loop" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/doc-utils.sh"

OUTPUT_MODE="json"
SECTION="full"

ARC_DOC=""
CANDIDATE=""
GRILL_DECISIONS_JSON=""
ADR_SLUG=""
ADR_REASON=""

KNOWLEDGE_DOC="docs/architecture/PROJECT-KNOWLEDGE.md"
ADR_DIR="docs/adr"
ADR_TEMPLATE="${HOME}/.claude/templates/architecture/adr.md"
LANGUAGE_TEMPLATE="${HOME}/.claude/templates/architecture/LANGUAGE.md"
DEEPENING_TEMPLATE="${HOME}/.claude/templates/architecture/DEEPENING.md"

GRILL_STATE_FILE=".arch-grill-state.json"

ARC_TASK_ID=""
ARC_FILENAME=""

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

# Locate ARC doc: explicit --arc-doc > newest active ARC
resolve_arc_doc() {
    if [[ -n "$ARC_DOC" ]]; then
        if [[ ! -f "$ARC_DOC" ]]; then
            exit_with_json "error" "ARC doc not found: $ARC_DOC" "Pass --arc-doc <path> or omit to use newest active ARC"
        fi
        return 0
    fi

    ARC_DOC=$(find docs/active -name "*-ARC-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    if [[ -z "$ARC_DOC" ]]; then
        exit_with_json "error" "No ARC document found under docs/active" "Run /arch-explore first"
    fi
}

#------------------------------------------------------------------------------
# Section: Identify ARC doc
#------------------------------------------------------------------------------

section_identify() {
    log "${BLUE}Identifying ARC Document${NC}"

    resolve_arc_doc

    ARC_FILENAME="$(basename "$ARC_DOC")"
    ARC_TASK_ID=$(get_task_id "$ARC_FILENAME")

    log "${GREEN}✓${NC} ARC: $ARC_FILENAME ($ARC_TASK_ID)"

    # Read the file body — LLM parses candidates from it (markdown is fluid)
    local body
    body=$(cat "$ARC_DOC")

    local knowledge_present="false"
    [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"

    local has_state="false"
    [[ -f "$GRILL_STATE_FILE" ]] && has_state="true"

    if [[ "$SECTION" == "identify" ]] || [[ "$SECTION" == "full" ]]; then
        log_json "$(jq -nc \
            --arg arc_doc "$ARC_DOC" \
            --arg arc_filename "$ARC_FILENAME" \
            --arg task_id "$ARC_TASK_ID" \
            --arg body "$body" \
            --arg knowledge_doc "$KNOWLEDGE_DOC" \
            --argjson knowledge_present "$knowledge_present" \
            --arg language_template "$LANGUAGE_TEMPLATE" \
            --arg deepening_template "$DEEPENING_TEMPLATE" \
            --argjson has_state "$has_state" \
            --arg state_file "$GRILL_STATE_FILE" \
            --arg candidate "${CANDIDATE:-}" \
            '{
                status: "success",
                section: "identify",
                next_action: "run_grilling_loop",
                arc_doc: $arc_doc,
                arc_filename: $arc_filename,
                task_id: $task_id,
                arc_body: $body,
                knowledge_doc: $knowledge_doc,
                knowledge_present: $knowledge_present,
                language_template: $language_template,
                deepening_template: $deepening_template,
                has_state: $has_state,
                state_file: $state_file,
                candidate: ($candidate | if . == "" then null else . end)
            }')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Save grilling state
#------------------------------------------------------------------------------

section_save_state() {
    resolve_arc_doc
    ARC_TASK_ID=$(get_task_id "$(basename "$ARC_DOC")")

    if [[ -z "$GRILL_DECISIONS_JSON" ]]; then
        exit_with_json "error" "No decisions provided" "Pass --decisions '<json>' w/ accumulated grilling decisions"
    fi

    if ! echo "$GRILL_DECISIONS_JSON" | jq empty 2>/dev/null; then
        exit_with_json "error" "Invalid JSON in --decisions" "Must be a JSON array or object"
    fi

    jq -n \
        --arg arc_doc "$ARC_DOC" \
        --arg task_id "$ARC_TASK_ID" \
        --arg candidate "${CANDIDATE:-}" \
        --arg updated "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson decisions "$GRILL_DECISIONS_JSON" \
        '{arc_doc: $arc_doc, task_id: $task_id, candidate: $candidate, updated: $updated, decisions: $decisions}' \
        > "$GRILL_STATE_FILE"

    log "${GREEN}✓${NC} Grill state saved to $GRILL_STATE_FILE"

    log_json "$(jq -nc \
        --arg task_id "$ARC_TASK_ID" \
        --arg file "$GRILL_STATE_FILE" \
        '{status:"success", section:"save-state", next_action:"display_summary", task_id:$task_id, state_file:$file, message:"Grilling state saved — safe to resume"}')"
    exit 0
}

#------------------------------------------------------------------------------
# Section: Load grilling state
#------------------------------------------------------------------------------

section_load_state() {
    resolve_arc_doc
    ARC_TASK_ID=$(get_task_id "$(basename "$ARC_DOC")")

    if [[ ! -f "$GRILL_STATE_FILE" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$ARC_TASK_ID" \
            '{status:"success", section:"load-state", next_action:"run_grilling_loop", task_id:$task_id, state_file:null, decisions:[], message:"No prior grill state — start fresh"}')"
        exit 0
    fi

    local state_task_id
    state_task_id=$(jq -r '.task_id // empty' "$GRILL_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$state_task_id" != "$ARC_TASK_ID" ]]; then
        log "${YELLOW}⚠${NC} Grill state is for $state_task_id, not $ARC_TASK_ID — ignoring"
        log_json "$(jq -nc \
            --arg task_id "$ARC_TASK_ID" \
            --arg other "$state_task_id" \
            '{status:"success", section:"load-state", next_action:"run_grilling_loop", task_id:$task_id, state_file:null, decisions:[], warning:("Ignored state from other ARC: " + $other)}')"
        exit 0
    fi

    log "${GREEN}✓${NC} Loaded grill state from $GRILL_STATE_FILE"
    log_json "$(jq --arg section "load-state" \
                   --arg next "resume_grilling" \
                   '. + {status:"success", section:$section, next_action:$next}' \
                   "$GRILL_STATE_FILE")"
    exit 0
}

#------------------------------------------------------------------------------
# Section: Write ADR
#------------------------------------------------------------------------------

section_write_adr() {
    if [[ -z "$ADR_SLUG" ]]; then
        exit_with_json "error" "Missing --slug" "Pass --slug <kebab-case-slug> for the ADR filename"
    fi
    if [[ ! "$ADR_SLUG" =~ ^[a-z0-9-]+$ ]]; then
        exit_with_json "error" "Invalid slug" "Slug must be lowercase kebab-case"
    fi
    if [[ -z "$ADR_REASON" ]]; then
        exit_with_json "error" "Missing --reason" "Pass --reason '<load-bearing reason>' — the rationale a future explorer would need"
    fi

    resolve_arc_doc
    ARC_FILENAME="$(basename "$ARC_DOC")"

    mkdir -p "$ADR_DIR"

    # Next ADR number — 4-digit zero-padded
    local last_num next_num
    last_num=$(find "$ADR_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.md' 2>/dev/null \
        | xargs -I{} basename {} \
        | sed -E 's/^([0-9]{4}).*/\1/' \
        | sort -n | tail -1 || echo "")
    if [[ -z "$last_num" ]]; then
        next_num="0001"
    else
        next_num=$(printf "%04d" $((10#$last_num + 1)))
    fi

    local adr_path="${ADR_DIR}/${next_num}-${ADR_SLUG}.md"

    if [[ -f "$adr_path" ]]; then
        exit_with_json "error" "ADR file already exists" "$adr_path"
    fi

    if [[ ! -f "$ADR_TEMPLATE" ]]; then
        exit_with_json "error" "ADR template missing" "$ADR_TEMPLATE"
    fi

    local title today
    title=$(echo "$ADR_SLUG" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
    today=$(date +%Y-%m-%d)

    # Render template — replace placeholders, drop boilerplate context lines
    sed \
        -e "s/\[NUMBER\]/${next_num}/g" \
        -e "s/\[TITLE\]/${title}/g" \
        -e "s/\[YYYY-MM-DD\]/${today}/g" \
        -e "s|\[ARC_DOC\]|${ARC_FILENAME}|g" \
        "$ADR_TEMPLATE" > "$adr_path"

    # Append the load-bearing reason as a heredoc so quoting is safe
    {
        echo ""
        echo "## Captured Rationale (from /arch-grill)"
        echo ""
        echo "$ADR_REASON"
    } >> "$adr_path"

    log "${GREEN}✓${NC} Wrote ADR: $adr_path"

    log_json "$(jq -nc \
        --arg adr_path "$adr_path" \
        --arg number "$next_num" \
        --arg slug "$ADR_SLUG" \
        --arg arc_doc "$ARC_DOC" \
        '{
            status: "success",
            section: "write-adr",
            next_action: "display_summary",
            adr_path: $adr_path,
            adr_number: $number,
            adr_slug: $slug,
            arc_doc: $arc_doc,
            message: "ADR drafted — edit if needed, then call --commit to stage"
        }')"
    exit 0
}

#------------------------------------------------------------------------------
# Section: Commit grilled ARC + side artifacts
#------------------------------------------------------------------------------

section_commit() {
    resolve_arc_doc
    ARC_FILENAME="$(basename "$ARC_DOC")"
    ARC_TASK_ID=$(get_task_id "$ARC_FILENAME")

    git add "$ARC_DOC"
    [[ -d "$ADR_DIR" ]] && git add "$ADR_DIR" 2>/dev/null || true

    if git diff --cached --quiet; then
        exit_with_json "error" "No changes to commit" "Edit ARC doc / write ADR first"
    fi

    "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
    [[ -f "docs/DOCUMENT-INDEX.md" ]] && git add "docs/DOCUMENT-INDEX.md" || true

    git commit -m "docs(arch): grilled deepening design ${ARC_TASK_ID}

Document: ${ARC_FILENAME}
Source: /arch-grill" >/dev/null

    local commit_hash
    commit_hash=$(git rev-parse HEAD)

    log "${GREEN}✓${NC} Committed: $commit_hash"

    # Grilled — checkpoint no longer needed
    if [[ -f "$GRILL_STATE_FILE" ]]; then
        rm -f "$GRILL_STATE_FILE"
        log "${GREEN}✓${NC} Cleared grill state file"
    fi

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
            next_command: "/arch-interfaces"
        }')"
    exit 0
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
            --save-state)  SECTION="save-state"; shift ;;
            --load-state)  SECTION="load-state"; shift ;;
            --write-adr)   SECTION="write-adr"; shift ;;
            --commit)      SECTION="commit"; shift ;;
            --arc-doc)     ARC_DOC="$2"; shift 2 ;;
            --candidate)   CANDIDATE="$2"; shift 2 ;;
            --decisions)   GRILL_DECISIONS_JSON="$2"; shift 2 ;;
            --slug)        ADR_SLUG="$2"; shift 2 ;;
            --reason)      ADR_REASON="$2"; shift 2 ;;
            *)             echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        identify|full) section_identify ;;
        save-state)    section_save_state ;;
        load-state)    section_load_state ;;
        write-adr)     section_write_adr ;;
        commit)        section_commit ;;
        *)             exit_with_json "error" "Unknown section: $SECTION" "Valid: identify, save-state, load-state, write-adr, commit, full" ;;
    esac
}

main "$@"

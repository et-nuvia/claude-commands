#!/usr/bin/env bash
set -euo pipefail

# analyze-command-health.sh - Find which of YOUR commands/scripts to improve
#
# Reads Claude Code transcripts in ~/.claude/projects, attributes every tool
# call to the slash command that was in effect when it ran, and ranks commands
# and backing scripts by wall-clock cost, failure rate, chattiness, and
# permission-prompt-causing shell hygiene violations.
#
# Complements analyze-conversations.sh: that script reports session-level
# aggregates (which skills/tools are popular); this one blames specific
# commands and scripts so there is something concrete to fix.
#
# Usage:
#   analyze-command-health.sh [--json|--raw|--toon] [--since <days>] [--limit <n>]
#                             [--project <dir>] [--command <name>] [--top <n>]
#                             [--min-calls <n>] [--stall <seconds>] [--all-scripts]
#                             [--cache | --no-cache] [--reset]
#
# Examples:
#   analyze-command-health.sh --json --since 30
#   analyze-command-health.sh --json --command task-continue
#   analyze-command-health.sh --raw --since 7 --top 5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Output Framework Setup
# ============================================================================

# These three are read by lib/output-framework.sh once it is sourced.
# shellcheck disable=SC2034
OUTPUT_MODE="json"
# shellcheck disable=SC2034
OUTPUT_FORMAT="${OUTPUT_FORMAT:-}"
# shellcheck disable=SC2034
SECTION=""

map_status_to_action() {
    case "$1" in
        ready_for_llm)  echo "review_recommendations" ;;
        no_data)        echo "display_summary" ;;
        *)              _default_map_status_to_action "$1" ;;
    esac
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output-framework.sh"

# ============================================================================
# Configuration
# ============================================================================

CLAUDE_DIR="${HOME}/.claude"
PROJECTS_DIR="${CLAUDE_DIR}/projects"
CACHE_DIR="${CLAUDE_DIR}/conversation-analysis/command-health"
EXTRACT_JQ="${SCRIPT_DIR}/lib/command-health.jq"
AGGREGATE_JQ="${SCRIPT_DIR}/lib/command-health-aggregate.jq"

SINCE_DAYS=30
FILE_LIMIT=0
TARGET_PROJECT=""
FILTER_COMMAND=""
TOP_N=10
MIN_CALLS=1
USE_CACHE=true
# Gaps beyond this are permission-prompt/idle waits, not execution time.
STALL_SECONDS=600
# Report only ~/.claude/scripts by default — third-party scripts aren't yours to fix.
ALL_SCRIPTS=false

# ============================================================================
# Helpers
# ============================================================================

# Per-transcript extraction is the expensive step, and transcripts are
# append-only-then-frozen, so cache keyed on size+mtime.
cache_key() {
    local file="$1" size mtime
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    mtime=$(stat -f%m "$file" 2>/dev/null || stat -c%Y "$file" 2>/dev/null)
    printf '%s-%s-%s' "$(basename "$file" .jsonl)" "$size" "$mtime"
}

# ============================================================================
# Sections
# ============================================================================

section_collect() {
    SECTION="collect"
    log "${BLUE}=== Collecting transcripts ===${NC}"

    local search_dir="$PROJECTS_DIR"
    if [[ -n "$TARGET_PROJECT" ]]; then
        search_dir="${PROJECTS_DIR}/${TARGET_PROJECT}"
        [[ -d "$search_dir" ]] || exit_with_json "error" \
            "Project directory not found: ${TARGET_PROJECT}" \
            "List available projects with: ls ${PROJECTS_DIR}"
    fi

    mkdir -p "$CACHE_DIR"
    FILE_LIST="${CACHE_DIR}/.files"

    if [[ "$SINCE_DAYS" -gt 0 ]]; then
        find "$search_dir" -maxdepth 2 -name '*.jsonl' -type f \
            -mtime "-${SINCE_DAYS}" -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null > "$FILE_LIST" || true
    else
        find "$search_dir" -maxdepth 2 -name '*.jsonl' -type f -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null > "$FILE_LIST" || true
    fi

    if [[ "$FILE_LIMIT" -gt 0 ]]; then
        head -n "$FILE_LIMIT" "$FILE_LIST" > "${FILE_LIST}.tmp"
        mv "${FILE_LIST}.tmp" "$FILE_LIST"
    fi

    FILE_COUNT=$(grep -c . "$FILE_LIST" || true)
    if [[ "${FILE_COUNT:-0}" -eq 0 ]]; then
        exit_with_json "no_data" \
            "No transcripts found in the last ${SINCE_DAYS} days" \
            "Widen the window with --since 0 (all history)"
    fi
    log "Found ${FILE_COUNT} transcripts"
}

section_extract() {
    SECTION="extract"
    log "${BLUE}=== Extracting per-command signals ===${NC}"

    local results="${CACHE_DIR}/results.jsonl"
    : > "$results"

    local n=0 hits=0 misses=0 failures=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        n=$((n + 1))
        local key cached
        key=$(cache_key "$file")
        cached="${CACHE_DIR}/${key}.json"

        if [[ "$USE_CACHE" == "true" && -s "$cached" ]]; then
            hits=$((hits + 1))
            cat "$cached" >> "$results"
            continue
        fi

        log "  [${n}/${FILE_COUNT}] $(basename "$file")"
        local project session out
        project=$(basename "$(dirname "$file")")
        session=$(basename "$file" .jsonl)

        if out=$(jq -s -f "$EXTRACT_JQ" --arg sid "$session" --arg proj "$project" \
                    --argjson stall "$STALL_SECONDS" "$file" 2>/dev/null) \
           && [[ -n "$out" && "$out" != "null" ]]; then
            printf '%s\n' "$out" > "$cached"
            printf '%s\n' "$out" >> "$results"
            misses=$((misses + 1))
        else
            failures=$((failures + 1))
            log "    ${YELLOW}skipped (unparseable)${NC}"
        fi
    done < "$FILE_LIST"

    EXTRACT_STATS="{\"transcripts\": ${n}, \"from_cache\": ${hits}, \"parsed\": ${misses}, \"unparseable\": ${failures}}"
    log "Extracted ${misses} (cache hits ${hits}, skipped ${failures})"

    [[ -s "$results" ]] || exit_with_json "no_data" \
        "No transcripts yielded usable data" \
        "Every candidate file failed to parse as JSONL"
}

section_report() {
    SECTION="report"
    log "${BLUE}=== Ranking improvement opportunities ===${NC}"

    local results="${CACHE_DIR}/results.jsonl"
    local filtered="$results"

    if [[ -n "$FILTER_COMMAND" ]]; then
        filtered="${CACHE_DIR}/results-filtered.jsonl"
        # bash_commands and reread_files are session-wide, not per-command, so
        # they are dropped rather than reported under a single command's name.
        jq -c --arg c "$FILTER_COMMAND" \
            '.commands |= map(select(.name == $c))
             | .scripts |= map(select(.commands | index($c)))
             | .bash_commands = [] | .reread_files = []' \
            "$results" > "$filtered"
    fi

    local findings
    findings=$(jq -s --argjson top "$TOP_N" --argjson all_scripts "$ALL_SCRIPTS" \
                  -f "$AGGREGATE_JQ" "$filtered" 2>/dev/null)
    [[ -n "$findings" && "$findings" != "null" ]] || exit_with_json "error" \
        "Aggregation failed" "Check that jq >= 1.6 is installed: jq --version"

    if [[ "$MIN_CALLS" -gt 1 ]]; then
        findings=$(printf '%s' "$findings" | jq --argjson m "$MIN_CALLS" \
            '.slowest_commands |= map(select(.invocations >= $m))
             | .chattiest_commands |= map(select(.invocations >= $m))')
    fi

    printf '%s' "$findings" > "${CACHE_DIR}/latest-report.json"

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "=== Command / Script Health ==="
        printf '%s' "$findings" | jq .
        return 0
    fi

    log_json "$(jq -n \
        --arg status "ready_for_llm" \
        --arg next_action "$(map_status_to_action ready_for_llm)" \
        --arg section "report" \
        --arg message "Ranked improvement opportunities for your commands and scripts" \
        --argjson window_days "$SINCE_DAYS" \
        --argjson extract "${EXTRACT_STATS:-null}" \
        --argjson findings "$findings" \
        '{ status: $status, next_action: $next_action, section: $section,
           message: $message, timestamp: now|todate,
           window_days: $window_days, extraction: $extract, findings: $findings }')"
}

section_prune() {
    SECTION="prune"
    rm -rf "$CACHE_DIR"
    exit_with_json "success" "Cleared extraction cache" "" "\"cache_dir\": \"${CACHE_DIR}\""
}

# ============================================================================
# Main
# ============================================================================

main() {
    local do_reset=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)      OUTPUT_MODE="json"; shift ;;
            --toon)      OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw)       OUTPUT_MODE="raw"; OUTPUT_FORMAT="json"; shift ;;
            --since)     SINCE_DAYS="$2"; shift 2 ;;
            --limit)     FILE_LIMIT="$2"; shift 2 ;;
            --project)   TARGET_PROJECT="$2"; shift 2 ;;
            --command)   FILTER_COMMAND="${2#/}"; shift 2 ;;
            --stall)        STALL_SECONDS="$2"; shift 2 ;;
            --all-scripts)  ALL_SCRIPTS=true; shift ;;
            --top)       TOP_N="$2"; shift 2 ;;
            --min-calls) MIN_CALLS="$2"; shift 2 ;;
            --cache)     USE_CACHE=true; shift ;;
            --no-cache)  USE_CACHE=false; shift ;;
            --reset)     do_reset=true; shift ;;
            -h|--help)
                sed -n '4,24p' "${BASH_SOURCE[0]}" >&2
                exit 0 ;;
            *)
                # shellcheck disable=SC2034
                SECTION="args"
                exit_with_json "error" "Unknown option: $1" "Run with --help for usage" ;;
        esac
    done

    [[ "$do_reset" == "true" ]] && section_prune

    section_collect
    section_extract
    section_report
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# analyze-conversations.sh - Analyze Claude Code conversation transcripts
#
# Scans .jsonl conversation files, extracts patterns (errors, retries,
# command usage, pain points), and identifies improvement opportunities.
# Tracks analyzed files in a manifest to avoid re-processing.
#
# Usage:
#   analyze-conversations.sh --json --full [--project <project-dir>] [--limit <n>] [--reset]
#   analyze-conversations.sh --json --summary
#   analyze-conversations.sh --raw --full

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Output Framework Setup
# ============================================================================

OUTPUT_MODE="json"
SECTION=""

map_status_to_action() {
    case "$1" in
        success)           echo "display_summary" ;;
        ready_for_llm)     echo "analyze_findings" ;;
        no_new_files)      echo "display_summary" ;;
        *)                 echo "fix_error" ;;
    esac
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output-framework.sh"

# ============================================================================
# Configuration
# ============================================================================

CLAUDE_DIR="${HOME}/.claude"
PROJECTS_DIR="${CLAUDE_DIR}/projects"
MANIFEST_FILE="${CLAUDE_DIR}/conversation-analysis-manifest.json"
ANALYSIS_DIR="${CLAUDE_DIR}/conversation-analysis"
TARGET_PROJECT=""
FILE_LIMIT=0  # 0 = no limit
RESET=false

# ============================================================================
# Helper Functions
# ============================================================================

ensure_dirs() {
    mkdir -p "${ANALYSIS_DIR}"
}

init_manifest() {
    if [[ ! -f "$MANIFEST_FILE" ]] || [[ "$RESET" == "true" ]]; then
        echo '{"analyzed_files": {}, "last_run": null, "total_runs": 0}' > "$MANIFEST_FILE"
        log "Initialized manifest"
    fi
}

is_analyzed() {
    local file="$1"
    local current_size current_mtime
    current_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    current_mtime=$(stat -c%Y "$file" 2>/dev/null || stat -f%m "$file" 2>/dev/null)

    local stored
    stored=$(jq -r --arg f "$file" '.analyzed_files[$f] // empty' "$MANIFEST_FILE" 2>/dev/null)
    if [[ -z "$stored" ]]; then
        return 1
    fi

    local stored_size stored_mtime
    stored_size=$(echo "$stored" | jq -r '.size')
    stored_mtime=$(echo "$stored" | jq -r '.mtime')

    [[ "$current_size" == "$stored_size" && "$current_mtime" == "$stored_mtime" ]]
}

mark_analyzed() {
    local file="$1"
    local current_size current_mtime
    current_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    current_mtime=$(stat -c%Y "$file" 2>/dev/null || stat -f%m "$file" 2>/dev/null)

    local tmp
    tmp=$(mktemp)
    jq --arg f "$file" \
       --argjson s "$current_size" \
       --argjson m "$current_mtime" \
       '.analyzed_files[$f] = {"size": $s, "mtime": $m, "analyzed_at": now | todate}' \
       "$MANIFEST_FILE" > "$tmp" && mv "$tmp" "$MANIFEST_FILE"
}

update_manifest_meta() {
    local tmp
    tmp=$(mktemp)
    jq '.last_run = (now | todate) | .total_runs += 1' "$MANIFEST_FILE" > "$tmp" && mv "$tmp" "$MANIFEST_FILE"
}

# ============================================================================
# Analysis Functions
# ============================================================================

# Extract signals from a single conversation file
# Outputs a JSON object with counts and patterns
analyze_file() {
    local file="$1"
    local session_id
    session_id=$(basename "$file" .jsonl)
    local project_dir
    project_dir=$(basename "$(dirname "$file")")

    # Extract relevant messages then analyze with jq file
    jq -c '
    select(.type == "user" or .type == "assistant" or .type == "tool-result" or .type == "error") |
    {type, message, toolUseResult, data}
    ' "$file" 2>/dev/null | \
    jq -sf "${SCRIPT_DIR}/lib/analyze-conversation.jq" \
        --arg sid "$session_id" \
        --arg proj "$project_dir" \
        2>/dev/null
}

# ============================================================================
# Section Functions
# ============================================================================

section_scan() {
    SECTION="scan"
    log "${BLUE}=== Scanning for conversation files ===${NC}"

    ensure_dirs
    init_manifest

    local search_dir="$PROJECTS_DIR"
    if [[ -n "$TARGET_PROJECT" ]]; then
        search_dir="${PROJECTS_DIR}/${TARGET_PROJECT}"
        if [[ ! -d "$search_dir" ]]; then
            exit_with_json "error" "Project directory not found: $TARGET_PROJECT" \
                "Available projects: $(ls "$PROJECTS_DIR" | tr '\n' ', ')"
        fi
    fi

    # Find all conversation files
    local all_files
    all_files=$(find "$search_dir" -maxdepth 2 -name "*.jsonl" -type f 2>/dev/null | sort)
    local total_count
    total_count=$(echo "$all_files" | grep -c . || echo 0)

    # Filter to unanalyzed files
    local new_files=()
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if ! is_analyzed "$file"; then
            new_files+=("$file")
        fi
    done <<< "$all_files"

    local new_count=${#new_files[@]}

    if [[ $new_count -eq 0 ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            exit_with_json "no_new_files" \
                "No new or modified conversations to analyze" "" \
                "\"total_files\": $total_count, \"already_analyzed\": $total_count"
        else
            echo "No new conversations to analyze ($total_count already processed)"
        fi
        return 0
    fi

    # Apply limit if set
    local process_files=("${new_files[@]}")
    if [[ $FILE_LIMIT -gt 0 && $new_count -gt $FILE_LIMIT ]]; then
        process_files=("${new_files[@]:0:$FILE_LIMIT}")
        new_count=$FILE_LIMIT
    fi

    log "Found $new_count new files to analyze (of $total_count total)"

    # Store file list for analyze section
    printf '%s\n' "${process_files[@]}" > "${ANALYSIS_DIR}/.pending-files"
    echo "$total_count" > "${ANALYSIS_DIR}/.total-count"
    echo "$new_count" > "${ANALYSIS_DIR}/.new-count"
}

section_analyze() {
    SECTION="analyze"
    log "${BLUE}=== Analyzing conversations ===${NC}"

    if [[ ! -f "${ANALYSIS_DIR}/.pending-files" ]]; then
        exit_with_json "error" "No pending files - run scan first"
    fi

    local results_file="${ANALYSIS_DIR}/batch-results.jsonl"
    > "$results_file"

    local count=0
    local total
    total=$(cat "${ANALYSIS_DIR}/.new-count")
    local errors=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        count=$((count + 1))
        log "  [$count/$total] Analyzing $(basename "$file")..."

        local result
        if result=$(analyze_file "$file" 2>/dev/null); then
            if [[ -n "$result" && "$result" != "null" ]]; then
                echo "$result" >> "$results_file"
                mark_analyzed "$file"
            else
                errors=$((errors + 1))
                log "    ${YELLOW}Warning: empty result${NC}"
            fi
        else
            errors=$((errors + 1))
            log "    ${RED}Error analyzing file${NC}"
        fi
    done < "${ANALYSIS_DIR}/.pending-files"

    update_manifest_meta
    log "Analyzed $count files ($errors errors)"
}

section_aggregate() {
    SECTION="aggregate"
    log "${BLUE}=== Aggregating results ===${NC}"

    local results_file="${ANALYSIS_DIR}/batch-results.jsonl"
    if [[ ! -f "$results_file" ]] || [[ ! -s "$results_file" ]]; then
        exit_with_json "error" "No results to aggregate - run analyze first"
    fi

    local total_files new_count
    total_files=$(cat "${ANALYSIS_DIR}/.total-count" 2>/dev/null || echo 0)
    new_count=$(cat "${ANALYSIS_DIR}/.new-count" 2>/dev/null || echo 0)

    # Aggregate all batch results into a summary
    local aggregate
    aggregate=$(jq -sc '{
      conversations_analyzed: length,
      total_messages: [.[].total_messages] | add,
      avg_messages_per_conversation: ([.[].total_messages] | add / length | floor),
      top_skills: [.[].skills_used[] | {name: .name, count: .count}] | group_by(.name) | map({name: .[0].name, total_uses: [.[].count] | add, sessions: length}) | sort_by(-.total_uses) | .[0:20],
      top_tools: [.[].tools_used[] | {name: .name, count: .count}] | group_by(.name) | map({name: .[0].name, total_uses: [.[].count] | add, sessions: length}) | sort_by(-.total_uses) | .[0:15],
      error_stats: {
        total_errors: [.[].errors] | add,
        sessions_with_errors: [.[] | select(.errors > 0)] | length,
        avg_errors_per_session: ([.[].errors] | add / length * 10 | floor / 10),
        high_error_sessions: [.[] | select(.errors > 10) | {session_id, project, errors, total_messages}] | sort_by(-.errors) | .[0:10]
      },
      correction_stats: {
        total_corrections: [.[].corrections] | add,
        sessions_with_corrections: [.[] | select(.corrections > 0)] | length,
        avg_corrections_per_session: ([.[].corrections] | add / length * 10 | floor / 10),
        high_correction_sessions: [.[] | select(.corrections > 5) | {session_id, project, corrections, total_messages}] | sort_by(-.corrections) | .[0:10]
      },
      retry_stats: {
        sessions_with_retries: [.[] | select((.retry_signals | length) > 0)] | length,
        common_retry_tools: [.[].retry_signals[] | {tool, repeated_calls}] | group_by(.tool) | map({tool: .[0].tool, total_retries: [.[].repeated_calls] | add, sessions: length}) | sort_by(-.total_retries) | .[0:10]
      },
      long_conversations: [.[] | select(.total_messages > 200) | {session_id, project, total_messages}] | sort_by(-.total_messages) | .[0:10],
      by_project: (group_by(.project) | map({project: .[0].project, conversations: length, total_errors: [.[].errors] | add, total_corrections: [.[].corrections] | add, avg_messages: ([.[].total_messages] | add / length | floor)}) | sort_by(-.conversations)),
      repeated_commands: [.[].bash_commands[] | {cmd: .cmd, count: .count}] | group_by(.cmd) | map({command: .[0].cmd, total_uses: [.[].count] | add, sessions: length}) | sort_by(-.total_uses) | map(select(.total_uses > 3)) | .[0:30],
      command_sequences: [.[].bash_sequences[] | {sequence: .sequence, count: .count}] | group_by(.sequence) | map({sequence: .[0].sequence, total: [.[].count] | add, sessions: length}) | sort_by(-.total) | map(select(.total > 5)) | .[0:20]
    }' "$results_file" 2>/dev/null)

    if [[ -z "$aggregate" || "$aggregate" == "null" ]]; then
        exit_with_json "error" "Failed to aggregate results"
    fi

    # Save aggregate for future reference
    echo "$aggregate" > "${ANALYSIS_DIR}/latest-aggregate.json"

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local next_action
        next_action=$(map_status_to_action "ready_for_llm")

        log_json "$(jq -n \
            --arg status "ready_for_llm" \
            --arg next_action "$next_action" \
            --arg section "aggregate" \
            --arg message "Analysis complete - review findings" \
            --argjson total_files "$total_files" \
            --argjson new_files "$new_count" \
            --argjson aggregate "$aggregate" \
            '{
                status: $status,
                next_action: $next_action,
                section: $section,
                message: $message,
                timestamp: now|todate,
                total_files: $total_files,
                new_files_analyzed: $new_files,
                findings: $aggregate
            }')"
    else
        echo "=== Conversation Analysis Summary ==="
        echo "$aggregate" | jq .
    fi
}

section_summary() {
    SECTION="summary"
    log "${BLUE}=== Loading previous analysis ===${NC}"

    if [[ ! -f "${ANALYSIS_DIR}/latest-aggregate.json" ]]; then
        exit_with_json "error" "No previous analysis found - run --full first"
    fi

    local aggregate
    aggregate=$(cat "${ANALYSIS_DIR}/latest-aggregate.json")

    local manifest_info
    manifest_info=$(jq '{last_run, total_runs, files_tracked: (.analyzed_files | length)}' "$MANIFEST_FILE" 2>/dev/null || echo '{}')

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local next_action
        next_action=$(map_status_to_action "ready_for_llm")

        log_json "$(jq -n \
            --arg status "ready_for_llm" \
            --arg next_action "$next_action" \
            --arg section "summary" \
            --arg message "Previous analysis loaded" \
            --argjson manifest "$manifest_info" \
            --argjson aggregate "$aggregate" \
            '{
                status: $status,
                next_action: $next_action,
                section: $section,
                message: $message,
                timestamp: now|todate,
                manifest: $manifest,
                findings: $aggregate
            }')"
    else
        echo "=== Previous Analysis ==="
        echo "$aggregate" | jq .
    fi
}

# ============================================================================
# Main Workflow
# ============================================================================

run_full_workflow() {
    section_scan
    # If scan exited (no new files), we're done
    if [[ ! -f "${ANALYSIS_DIR}/.pending-files" ]] || [[ ! -s "${ANALYSIS_DIR}/.pending-files" ]]; then
        return 0
    fi
    section_analyze
    section_aggregate
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    local section="full"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)     OUTPUT_MODE="json"; shift ;;
            --raw)      OUTPUT_MODE="raw"; shift ;;
            --full)     section="full"; shift ;;
            --scan)     section="scan"; shift ;;
            --analyze)  section="analyze"; shift ;;
            --aggregate) section="aggregate"; shift ;;
            --summary)  section="summary"; shift ;;
            --project)  TARGET_PROJECT="$2"; shift 2 ;;
            --limit)    FILE_LIMIT="$2"; shift 2 ;;
            --reset)    RESET=true; shift ;;
            -h|--help)
                echo "Usage: $0 [--json|--raw] [--full|--scan|--analyze|--aggregate|--summary] [--project <dir>] [--limit <n>] [--reset]" >&2
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 2
                ;;
        esac
    done

    case "$section" in
        full)      run_full_workflow ;;
        scan)      section_scan ;;
        analyze)   section_analyze ;;
        aggregate) section_aggregate ;;
        summary)   section_summary ;;
        *)
            SECTION="unknown"
            exit_with_json "error" "Unknown section: $section" \
                "Valid sections: full, scan, analyze, aggregate, summary"
            ;;
    esac
}

main "$@"

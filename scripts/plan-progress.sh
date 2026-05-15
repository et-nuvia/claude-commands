#!/usr/bin/env bash
# plan-progress.sh - Parse PLN checkboxes, report phase/next items
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/plan-progress.sh [--json|--raw] [--file <path>] [--mark-complete "<item>" ...]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Workflow:
#   1. LLM calls: plan-progress.sh --json
#   2. Returns current phase, progress counts, next 3 unchecked items
#   3. After completing work: plan-progress.sh --json --mark-complete "item text"

set -euo pipefail

# Portable sed -i (macOS requires '' arg, GNU does not)
sed_i() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Global variables
OUTPUT_MODE="json"
PLN_FILE=""
MARK_COMPLETE=()
declare -A ACTUAL_TIMES
PROGRESS_NOTE=""
LESSONS=""
TASK_LABEL=""
WENT_WELL=""
CHALLENGES_NOTE=""
DO_DIFFERENTLY=""
PATTERNS=""
EXTRACT_ENTRIES=false

# Source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/doc-utils.sh"
SECTION="plan-progress"
source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

output_json() {
    local status="$1"
    local next_action="$2"
    local message="$3"
    shift 3
    local extra_fields="$*"

    local json_base
    json_base=$(cat <<EOF
{
  "status": "$status",
  "next_action": "$next_action",
  "message": "$message",
  "timestamp": "$(date -Iseconds)"
EOF
)

    if [[ -n "$extra_fields" ]]; then
        json_base="${json_base},
  ${extra_fields}
}"
    else
        json_base="${json_base}
}"
    fi

    log_json "$json_base"
}

#------------------------------------------------------------------------------
# Find PLN file
#------------------------------------------------------------------------------

find_pln() {
    # If explicit file given, use it
    if [[ -n "$PLN_FILE" ]]; then
        if [[ -f "$PLN_FILE" ]]; then
            echo "$PLN_FILE"
            return 0
        fi
        return 1
    fi

    # Extract task ID from branch name
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")

    if [[ -n "$branch" ]]; then
        # Branch format: feature/XXXX-description or XXXX-description
        local seq=""
        if [[ "$branch" =~ ^[a-zA-Z]+/([0-9A-Fa-f]+)- ]]; then
            seq="${BASH_REMATCH[1]}"
        elif [[ "$branch" =~ ^([0-9A-Fa-f]+)- ]]; then
            seq="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$seq" ]]; then
            seq="${seq^^}"
            local docs_dir
            docs_dir=$(find_docs_dir 2>/dev/null) || true
            if [[ -n "$docs_dir" ]]; then
                local pln
                pln=$(find "$docs_dir/active" -name "${seq}-*-PLN-*.md" 2>/dev/null | head -1)
                if [[ -n "$pln" ]]; then
                    echo "$pln"
                    return 0
                fi
            fi
        fi
    fi

    # Fallback: most recent PLN in active docs
    local docs_dir
    docs_dir=$(find_docs_dir 2>/dev/null) || true
    if [[ -n "$docs_dir" ]]; then
        local pln
        pln=$(find "$docs_dir/active" -name "*-PLN-*.md" 2>/dev/null | sort -r | head -1)
        if [[ -n "$pln" ]]; then
            echo "$pln"
            return 0
        fi
    fi

    return 1
}

#------------------------------------------------------------------------------
# Parse PLN checkboxes and phases
#------------------------------------------------------------------------------

parse_progress() {
    local file="$1"

    local done_count=0
    local pending_count=0
    local total_count=0
    local current_phase=""
    local current_phase_done=0
    local current_phase_pending=0
    local next_items=""
    local next_count=0

    local in_phase=""

    while IFS= read -r line; do
        # Detect phase headers (## Phase or ### Phase)
        if [[ "$line" =~ ^#{2,3}[[:space:]]+(.+) ]]; then
            local phase_name="${BASH_REMATCH[1]}"
            # Skip non-phase headers like "## Context" or "## Summary"
            if [[ "$phase_name" =~ [Pp]hase|[Ss]tep|[Ss]tage|[Pp]art ]]; then
                in_phase="$phase_name"
            fi
        fi

        # Count checked items: "- [x] ..." or "#### Task N: [x] ..."
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[x\][[:space:]](.+) ]] || \
           [[ "$line" =~ ^#{1,6}[[:space:]].*\[x\][[:space:]](.+) ]]; then
            done_count=$((done_count + 1))
            total_count=$((total_count + 1))
            if [[ -n "$in_phase" ]]; then
                current_phase="$in_phase"
                current_phase_done=$((current_phase_done + 1))
            fi
        fi

        # Count unchecked items and collect next items: "- [ ] ..." or "#### Task N: [ ] ..."
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]](.+) ]] || \
           [[ "$line" =~ ^#{1,6}[[:space:]].*\[[[:space:]]\][[:space:]](.+) ]]; then
            pending_count=$((pending_count + 1))
            total_count=$((total_count + 1))

            if [[ -n "$in_phase" ]] && [[ -z "$current_phase" || "$current_phase" == "$in_phase" ]]; then
                current_phase="$in_phase"
                current_phase_pending=$((current_phase_pending + 1))
            fi

            # Collect up to 3 next items
            if [[ $next_count -lt 3 ]]; then
                local item_text="${BASH_REMATCH[1]}"
                # Escape quotes for JSON
                item_text="${item_text//\"/\\\"}"
                if [[ $next_count -gt 0 ]]; then
                    next_items="${next_items}, "
                fi
                next_items="${next_items}\"${item_text}\""
                next_count=$((next_count + 1))
            fi
        fi
    done < "$file"

    # Determine progress percentage
    local percent=0
    if [[ $total_count -gt 0 ]]; then
        percent=$(( (done_count * 100) / total_count ))
    fi

    # Build JSON output
    local next_action="continue_implementation"
    local message="$done_count of $total_count items complete ($percent%)"
    if [[ $pending_count -eq 0 ]]; then
        next_action="display_summary"
        message="All $total_count items complete"
    fi

    # Escape current_phase for JSON
    current_phase="${current_phase//\"/\\\"}"

    # Extract execution config from next unchecked task block
    local task_config=""
    if [[ $pending_count -gt 0 ]]; then
        task_config=$(extract_next_task_config "$file")
    fi

    local config_fragment=""
    if [[ -n "$task_config" ]]; then
        config_fragment=",
  $task_config"
    fi

    output_json "success" "$next_action" "$message" \
        "\"plan_file\": \"$file\",
  \"progress\": {
    \"done\": $done_count,
    \"pending\": $pending_count,
    \"total\": $total_count,
    \"percent\": $percent
  },
  \"current_phase\": \"$current_phase\",
  \"next_items\": [$next_items]${config_fragment}"
}

#------------------------------------------------------------------------------
# Extract execution config from next unchecked task block
#------------------------------------------------------------------------------

extract_next_task_config() {
    local file="$1"

    # Defaults
    local work_model="sonnet"
    local test_model="n/a"
    local tdd_required="no"
    local auto_review="no"
    local review_type="single"
    local fresh_context="no"

    local in_task_block=false

    while IFS= read -r line; do
        # Detect unchecked task heading: #### Task N.M: [ ] ...
        if [[ "$in_task_block" == "false" ]] && \
           [[ "$line" =~ ^#{1,6}[[:space:]].*\[[[:space:]]\] ]]; then
            in_task_block=true
            continue
        fi

        # If we're in the task block, extract fields
        if [[ "$in_task_block" == "true" ]]; then
            # Stop at next heading or empty line (but allow field lines)
            if [[ "$line" =~ ^#{1,6}[[:space:]] ]]; then
                break
            fi
            if [[ -z "$line" ]]; then
                break
            fi

            # Extract field values: - **Field Name**: value
            if [[ "$line" =~ ^-[[:space:]]\*\*Work\ Model\*\*:[[:space:]]*(.+) ]]; then
                work_model=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | xargs)
            elif [[ "$line" =~ ^-[[:space:]]\*\*Test\ Model\*\*:[[:space:]]*(.+) ]]; then
                test_model=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | xargs)
            elif [[ "$line" =~ ^-[[:space:]]\*\*TDD\ Required\*\*:[[:space:]]*(.+) ]]; then
                tdd_required=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | xargs)
            elif [[ "$line" =~ ^-[[:space:]]\*\*Auto\ Review\*\*:[[:space:]]*(.+) ]]; then
                auto_review=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | xargs)
            elif [[ "$line" =~ ^-[[:space:]]\*\*Review\ Type\*\*:[[:space:]]*(.+) ]]; then
                review_type=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | xargs)
            elif [[ "$line" =~ ^-[[:space:]]\*\*Fresh\ Context\*\*:[[:space:]]*(.+) ]]; then
                fresh_context=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | xargs)
            fi
        fi
    done < "$file"

    # Validate values — fall back to defaults for invalid input
    case "$tdd_required" in
        yes|no|recommend) ;;
        *) tdd_required="no" ;;
    esac
    case "$auto_review" in
        yes|no) ;;
        *) auto_review="no" ;;
    esac
    case "$review_type" in
        single|two-stage) ;;
        *) review_type="single" ;;
    esac
    case "$fresh_context" in
        yes|no) ;;
        *) fresh_context="no" ;;
    esac

    # Output JSON fragment
    cat <<EOF
"next_task_config": {
    "work_model": "$work_model",
    "test_model": "$test_model",
    "tdd_required": "$tdd_required",
    "auto_review": "$auto_review",
    "review_type": "$review_type",
    "fresh_context": "$fresh_context"
  }
EOF
}

#------------------------------------------------------------------------------
# Update actual time for a task
#------------------------------------------------------------------------------

update_actual_time() {
    local file="$1"
    local task_heading_line="$2"
    local time_value="$3"

    # Search forward from the task heading for "- **Actual Time**:" (update) or
    # "- **Estimated Time**:" (insert-after). Stops at next heading.
    local file_length
    file_length=$(wc -l < "$file")
    local search_start=$((task_heading_line + 1))
    local estimated_line=""

    local i
    for (( i=search_start; i<=file_length; i++ )); do
        local line
        line=$(sed -n "${i}p" "$file")

        if [[ "$line" =~ ^#{1,6}[[:space:]] ]]; then
            break
        fi

        if [[ "$line" =~ ^-[[:space:]]\*\*Actual\ Time\*\*: ]]; then
            sed_i "${i}s/- \*\*Actual Time\*\*:.*/- **Actual Time**: ${time_value}/" "$file"
            log "${GREEN}Set actual time: $time_value${NC}"
            return 0
        fi

        if [[ "$line" =~ ^-[[:space:]]\*\*Estimated\ Time\*\*: ]]; then
            estimated_line=$i
        fi
    done

    # No existing Actual Time line — insert one right after Estimated Time if found.
    if [[ -n "$estimated_line" ]]; then
        # sed `a` appends a line after the addressed line; portable form for BSD + GNU.
        sed_i "${estimated_line}a\\
- **Actual Time**: ${time_value}
" "$file"
        log "${GREEN}Inserted actual time: $time_value${NC}"
        return 0
    fi

    return 1
}

#------------------------------------------------------------------------------
# Mark item complete
#------------------------------------------------------------------------------

mark_complete() {
    local file="$1"
    local item_text="$2"

    # Strip leading [AC#] tags from input so callers can pass text with or without them
    local search_text="$item_text"
    search_text=$(echo "$search_text" | sed 's/^\(\[AC[0-9x]*\]\s*\)*//')

    # Use fixed-string grep to find the line number, then sed by line number
    local line_num
    line_num=$(grep -nF "[ ] " "$file" | grep -F "$search_text" | head -1 | cut -d: -f1)

    if [[ -n "$line_num" ]]; then
        # Handle both "- [ ]" (flat checklist) and ": [ ]" (#### Task heading) formats
        sed_i "${line_num}s/\[ \]/[x]/" "$file"
        log "${GREEN}Marked complete: $item_text${NC}"

        # Update actual time if provided for this task
        # Extract task number from heading (e.g., "Task 1.2:" → "1.2")
        local full_line
        full_line=$(sed -n "${line_num}p" "$file")
        if [[ "$full_line" =~ Task[[:space:]]+([0-9]+\.[0-9]+) ]]; then
            local task_num="${BASH_REMATCH[1]}"
            if [[ -n "${ACTUAL_TIMES[$task_num]+_}" ]]; then
                update_actual_time "$file" "$line_num" "${ACTUAL_TIMES[$task_num]}"
            fi
        fi

        sync_tsk_criteria "$file" "$full_line"

        return 0
    else
        log "${RED}Item not found: $item_text${NC}"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Sync TSK acceptance criteria from PLN [AC#] tags
#------------------------------------------------------------------------------

# Extract [AC#] tags from a PLN item line
extract_ac_tags() {
    local text="$1"
    # Match [AC1], [AC2], etc. — not [ACx] (infrastructure marker)
    echo "$text" | grep -oE '\[AC[0-9]+\]' || true
}

# Check if all PLN items with a given [AC#] tag are complete
all_items_complete_for_tag() {
    local file="$1"
    local tag="$2"

    # Find all lines containing this tag
    local pending
    pending=$(grep -c "^\s*- \[ \].*$(sed 's/\[/\\[/g;s/\]/\\]/g' <<< "$tag")" "$file" 2>/dev/null || echo "0")
    pending=${pending//[^0-9]/}
    pending=${pending:-0}

    [[ "$pending" -eq 0 ]]
}

# Find the TSK document for this PLN file and mark the matching criterion
sync_tsk_criteria() {
    local pln_file="$1"
    local item_text="$2"

    # Extract AC tags from the completed item
    local tags
    tags=$(extract_ac_tags "$item_text")
    if [[ -z "$tags" ]]; then
        return 0
    fi

    # Get task ID from PLN filename (first 6 hex chars)
    local pln_basename
    pln_basename=$(basename "$pln_file")
    local task_id=""
    if [[ "$pln_basename" =~ ^([A-Fa-f0-9]{6})- ]]; then
        task_id="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$task_id" ]]; then
        return 0
    fi

    # Find the TSK document
    local tsk_doc
    tsk_doc=$(find_primary "$task_id" 2>/dev/null || true)
    if [[ -z "$tsk_doc" ]] || [[ ! -f "$tsk_doc" ]]; then
        return 0
    fi

    # For each AC tag, check if all PLN items with that tag are complete
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        if all_items_complete_for_tag "$pln_file" "$tag"; then
            # Extract the criterion number (e.g., AC3 → 3)
            local ac_num
            ac_num=$(echo "$tag" | sed 's/\[AC\([0-9]*\)\]/\1/')

            # Find the matching unchecked criterion in TSK
            # Match pattern: "- [ ] AC#:" or "- [ ] **AC#**:" or numbered like "- [ ] 3."
            local tsk_line
            tsk_line=$(grep -n "^\s*- \[ \].*AC${ac_num}[^0-9]" "$tsk_doc" 2>/dev/null | head -1 | cut -d: -f1)

            if [[ -n "$tsk_line" ]]; then
                sed_i "${tsk_line}s/- \[ \]/- [x]/" "$tsk_doc"
                log "${GREEN}Auto-marked TSK criterion AC${ac_num} in $(basename "$tsk_doc")${NC}"
            fi
        fi
    done <<< "$tags"
}

#------------------------------------------------------------------------------
# Append progress entry to PLN
#------------------------------------------------------------------------------

append_progress_entry() {
    local file="$1"

    # Build the entry
    local heading
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M")
    if [[ -n "$TASK_LABEL" ]]; then
        heading="### ${timestamp} - ${TASK_LABEL}"
    else
        heading="### ${timestamp}"
    fi

    local entry="${heading}"
    if [[ -n "$PROGRESS_NOTE" ]]; then
        entry="${entry}
- **Progress**: ${PROGRESS_NOTE}"
    fi
    if [[ -n "$LESSONS" ]]; then
        entry="${entry}
- **Lessons Learned**: ${LESSONS}"
    fi
    if [[ -n "$WENT_WELL" ]]; then
        entry="${entry}
- **Went Well**: ${WENT_WELL}"
    fi
    if [[ -n "$CHALLENGES_NOTE" ]]; then
        entry="${entry}
- **Challenges**: ${CHALLENGES_NOTE}"
    fi
    if [[ -n "$DO_DIFFERENTLY" ]]; then
        entry="${entry}
- **Do Differently**: ${DO_DIFFERENTLY}"
    fi
    if [[ -n "$PATTERNS" ]]; then
        entry="${entry}
- **Reusable Patterns**: ${PATTERNS}"
    fi

    # Find the "## Progress & Lessons Learned" section
    local section_line
    section_line=$(grep -n "^## Progress & Lessons Learned" "$file" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -n "$section_line" ]]; then
        # Find the line after the section header (skip optional description line)
        local insert_line=$((section_line + 1))
        local next_line
        next_line=$(sed -n "${insert_line}p" "$file")
        # Skip the template description line if present
        if [[ "$next_line" =~ ^\[This\ section ]]; then
            insert_line=$((insert_line + 1))
        fi

        # Insert the entry after the section header using temp file (portable)
        local tmpfile
        tmpfile=$(mktemp)
        {
            head -n "$insert_line" "$file"
            printf '\n%s\n' "$entry"
            tail -n +"$((insert_line + 1))" "$file"
        } > "$tmpfile"
        mv "$tmpfile" "$file"
        log "${GREEN}Appended progress entry${NC}"
    else
        # No section found — append to end of file
        printf '\n## Progress & Lessons Learned\n\n%s\n' "$entry" >> "$file"
        log "${GREEN}Created progress section with entry${NC}"
    fi
}

#------------------------------------------------------------------------------
# Extract progress entries from PLN as JSON
#------------------------------------------------------------------------------

extract_progress_entries() {
    local file="$1"

    local in_section=false
    local entries="[]"
    local current_timestamp=""
    local current_label=""
    local current_progress=""
    local current_lessons=""
    local current_went_well=""
    local current_challenges=""
    local current_differently=""
    local current_patterns=""

    flush_entry() {
        if [[ -z "$current_timestamp" ]]; then
            return
        fi
        local entry
        entry=$(jq -n \
            --arg ts "$current_timestamp" \
            --arg label "$current_label" \
            --arg progress "$current_progress" \
            --arg lessons "$current_lessons" \
            --arg went_well "$current_went_well" \
            --arg challenges "$current_challenges" \
            --arg differently "$current_differently" \
            --arg patterns "$current_patterns" \
            '{timestamp: $ts, label: $label, progress: $progress, lessons: $lessons, went_well: $went_well, challenges: $challenges, do_differently: $differently, reusable_patterns: $patterns}')
        entries=$(echo "$entries" | jq --argjson e "$entry" '. + [$e]')
        current_timestamp=""
        current_label=""
        current_progress=""
        current_lessons=""
        current_went_well=""
        current_challenges=""
        current_differently=""
        current_patterns=""
    }

    while IFS= read -r line; do
        # Detect start of Progress & Lessons Learned section
        if [[ "$line" =~ ^##[[:space:]]+Progress[[:space:]]\&[[:space:]]Lessons ]]; then
            in_section=true
            continue
        fi

        # End of section at next ## heading
        if [[ "$in_section" == "true" ]] && [[ "$line" =~ ^##[[:space:]] ]] && ! [[ "$line" =~ ^###[[:space:]] ]]; then
            flush_entry
            break
        fi

        if [[ "$in_section" != "true" ]]; then
            continue
        fi

        # New entry heading: ### YYYY-MM-DD HH:MM - Label
        if [[ "$line" =~ ^###[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2})[[:space:]]*-?[[:space:]]*(.*) ]]; then
            flush_entry
            current_timestamp="${BASH_REMATCH[1]}"
            current_label="${BASH_REMATCH[2]}"
            continue
        fi

        # Field lines within an entry
        if [[ "$line" =~ ^-[[:space:]]\*\*Progress\*\*:[[:space:]]*(.*) ]]; then
            current_progress="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]\*\*Lessons\ Learned\*\*:[[:space:]]*(.*) ]]; then
            current_lessons="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]\*\*Went\ Well\*\*:[[:space:]]*(.*) ]]; then
            current_went_well="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]\*\*Challenges\*\*:[[:space:]]*(.*) ]]; then
            current_challenges="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]\*\*Do\ Differently\*\*:[[:space:]]*(.*) ]]; then
            current_differently="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]\*\*Reusable\ Patterns\*\*:[[:space:]]*(.*) ]]; then
            current_patterns="${BASH_REMATCH[1]}"
        fi
    done < "$file"

    # Flush last entry if file ends without another ## heading
    if [[ "$in_section" == "true" ]]; then
        flush_entry
    fi

    log_json "$entries"
}

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --file) PLN_FILE="$2"; shift 2 ;;
        --mark-complete) MARK_COMPLETE+=("$2"); shift 2 ;;
        --actual-time)
            # Parse "1.1=45m,1.2=1h" into associative array
            IFS=',' read -ra _at_pairs <<< "$2"
            for _at_pair in "${_at_pairs[@]}"; do
                _at_key="${_at_pair%%=*}"
                _at_val="${_at_pair#*=}"
                _at_key=$(echo "$_at_key" | xargs)
                _at_val=$(echo "$_at_val" | xargs)
                ACTUAL_TIMES["$_at_key"]="$_at_val"
            done
            shift 2
            ;;
        --progress) PROGRESS_NOTE="$2"; shift 2 ;;
        --lessons) LESSONS="$2"; shift 2 ;;
        --task-label) TASK_LABEL="$2"; shift 2 ;;
        --went-well) WENT_WELL="$2"; shift 2 ;;
        --challenges) CHALLENGES_NOTE="$2"; shift 2 ;;
        --differently) DO_DIFFERENTLY="$2"; shift 2 ;;
        --patterns) PATTERNS="$2"; shift 2 ;;
        --extract-entries) EXTRACT_ENTRIES=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] [--file <path>] [--mark-complete \"<item>\" ...] [--actual-time \"1.1=45m\"] [--progress \"note\"] [--lessons \"text\"] [--task-label \"Task 1.2\"] [--went-well \"...\"] [--challenges \"...\"] [--differently \"...\"] [--patterns \"...\"] [--extract-entries]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# Find PLN file
PLN_PATH=""
if ! PLN_PATH=$(find_pln); then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        output_json "error" "fix_error" "No PLN file found" \
            "\"hint\": \"Create a plan document or specify --file <path>\""
    else
        echo -e "${RED}Error: No PLN file found${NC}" >&2
    fi
    exit 1
fi

log "${BLUE}PLN file: $PLN_PATH${NC}"

# If marking complete, do that first
if [[ ${#MARK_COMPLETE[@]} -gt 0 ]]; then
    local_marked=0
    local_failed=()
    for mc_item in "${MARK_COMPLETE[@]}"; do
        if mark_complete "$PLN_PATH" "$mc_item"; then
            ((local_marked++)) || true
        else
            local_failed+=("$mc_item")
        fi
    done
    if [[ ${#local_failed[@]} -gt 0 ]]; then
        failed_list=$(printf ', %s' "${local_failed[@]}")
        failed_list="${failed_list:2}"  # strip leading ", "
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            output_json "error" "fix_error" "Could not find ${#local_failed[@]} item(s): $failed_list" \
                "\"marked\": $local_marked, \"failed_count\": ${#local_failed[@]}"
        else
            echo -e "${RED}Could not find ${#local_failed[@]} item(s): $failed_list${NC}" >&2
        fi
        exit 1
    fi
fi

# Append progress entry if we have any content to write
if [[ -n "$PROGRESS_NOTE" ]] || [[ -n "$LESSONS" ]] || [[ -n "$WENT_WELL" ]] || \
   [[ -n "$CHALLENGES_NOTE" ]] || [[ -n "$DO_DIFFERENTLY" ]] || [[ -n "$PATTERNS" ]]; then
    append_progress_entry "$PLN_PATH"
fi

# Extract entries mode — output JSON and exit
if [[ "$EXTRACT_ENTRIES" == "true" ]]; then
    extract_progress_entries "$PLN_PATH"
    exit 0
fi

# Parse and report progress
if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo ""
    echo "PLN: $PLN_PATH"
    echo ""
    # Simple raw output
    local_done=$(grep -cE '^\s*- \[x\]|^#{1,6}\s.*\[x\]' "$PLN_PATH" 2>/dev/null || echo "0")
    local_pending=$(grep -cE '^\s*- \[ \]|^#{1,6}\s.*\[ \]' "$PLN_PATH" 2>/dev/null || echo "0")
    local_total=$((local_done + local_pending))
    echo "Progress: $local_done / $local_total complete"
    echo ""
    echo "Next items:"
    grep -E '^\s*- \[ \]|^#{1,6}\s.*\[ \]' "$PLN_PATH" | head -3 | sed 's/.*\[ \] /  - /'
else
    parse_progress "$PLN_PATH"
fi

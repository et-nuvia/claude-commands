#!/usr/bin/env bash
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$_SD}"
# plan-progress.sh - Parse PLN checkboxes, report phase/next items
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/plan-progress.sh [--json|--raw] [--file <path>] [--mark-complete "<item>" ...]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Workflow:
#   1. LLM calls: plan-progress.sh --json
#   2. Returns current phase, progress counts, next 3 unchecked items
#   3. After completing work: plan-progress.sh --json --mark-complete "item text"

set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: requires bash >= 4 (on macOS: brew install bash)" >&2
  exit 1
fi

# Portable sed -i (macOS requires '' arg, GNU does not)
sed_i() {
    source "${SCRIPT_DIR}/lib/platform.sh"
    if env_is_darwin; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Trim leading/trailing whitespace.
#
# This replaces the `| xargs` idiom that used to be used for trimming throughout
# this script. `xargs` is a WORD SPLITTER, not a trimmer: it parses quotes, so any
# field containing an apostrophe or a lone double quote aborted the whole script
# with "xargs: unterminated quote" and exit 1. PLN prose is full of them —
# "the runner's own claim", "the repo's root commit" — so `--task-detail` failed
# on ordinary plans and the caller had to fall back to reading the PLN by hand.
# xargs also collapsed internal whitespace and ate backslashes, silently
# corrupting field values it did not outright reject.
#
# Pure bash, no subprocess, safe for every byte a PLN can contain.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
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
TASK_DETAIL=""

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
                pln=$(find "$docs_dir/active" -name "${seq}-*-PLN-*.md" 2>/dev/null | newest_doc)
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
        # `sort -r | head -1` ranked by full path, so this picked the last month folder
        # rather than the newest document; newest_doc ranks by the filename datetime.
        pln=$(find "$docs_dir/active" -name "*-PLN-*.md" 2>/dev/null | newest_doc)
        if [[ -n "$pln" ]]; then
            echo "$pln"
            return 0
        fi
    fi

    return 1
}

#------------------------------------------------------------------------------
# Dependency graph → ready set
#------------------------------------------------------------------------------

# Build the subtask dependency graph and return the set of pending subtasks whose
# dependencies are all satisfied — i.e. the items that may be dispatched RIGHT NOW,
# in parallel, without violating ordering.
#
# Why this lives in the script and not the command prompt: deciding "can 1.2 and 1.3
# run together?" is a graph reachability question over declared edges. An LLM asked to
# eyeball it either gets it wrong or (far more common) plays safe and serializes
# everything, which is why parallel dispatch was effectively dead. Computed here it is
# deterministic and free.
#
# Args: $1 = PLN file, $2 = current phase heading text (may be empty)
# Echoes a JSON fragment: "ready_items": [...], "ready_count": N, "deps_declared": bool
compute_ready_items() {
    local file="$1"
    local current_phase="${2:-}"

    local -a t_ids=() t_status=() t_phase=() t_deps=() t_text=()
    local -A resolved=()          # task_id → 1 when done/skipped
    local -A phase_total=() phase_open=()

    local in_phase="" cur_id="" cur_status="" cur_text="" seen_blank=0
    local phase_num=""

    # Single pass: collect one record per "#### Task N.M:" heading plus its
    # Dependencies field. Field extraction stops at the first blank line, matching
    # the config extractor's contract (see task-PLN.md).
    while IFS= read -r line; do
        if [[ "$line" =~ ^#{2,3}[[:space:]]+(.+) ]]; then
            local ph="${BASH_REMATCH[1]}"
            if [[ "$ph" =~ ^([Pp]hase|[Ss]tep|[Ss]tage|[Pp]art)[[:space:]:]*([0-9]+) ]]; then
                in_phase="$ph"
                phase_num="${BASH_REMATCH[2]}"
            elif [[ "$ph" =~ ^([Pp]hase|[Ss]tep|[Ss]tage|[Pp]art)([[:space:]]|:) ]]; then
                in_phase="$ph"
                phase_num=""
            else
                in_phase=""
                phase_num=""
            fi
            cur_id=""
            continue
        fi

        if [[ "$line" =~ ^####[[:space:]]+Task[[:space:]]+([0-9]+(\.[0-9]+)*):[[:space:]]*\[(.)\][[:space:]]*(.*) ]]; then
            cur_id="${BASH_REMATCH[1]}"
            cur_status="${BASH_REMATCH[3]}"
            cur_text="${BASH_REMATCH[4]}"
            seen_blank=0
            t_ids+=("$cur_id")
            t_status+=("$cur_status")
            t_phase+=("$in_phase")
            t_text+=("$cur_text")
            t_deps+=("")            # filled in by the Dependencies line below
            local major="${cur_id%%.*}"
            phase_total["$major"]=$(( ${phase_total[$major]:-0} + 1 ))
            case "$cur_status" in
                x|X|-|~) resolved["$cur_id"]=1 ;;
                *)       phase_open["$major"]=$(( ${phase_open[$major]:-0} + 1 )) ;;
            esac
            continue
        fi

        [[ -z "$cur_id" ]] && continue

        # Blank line closes the field block for this task
        if [[ -z "${line// /}" ]]; then
            seen_blank=1
            continue
        fi
        [[ $seen_blank -eq 1 ]] && continue

        if [[ "$line" =~ ^-[[:space:]]+\*\*Dependencies\*\*:[[:space:]]*(.*) ]]; then
            t_deps[$(( ${#t_deps[@]} - 1 ))]="${BASH_REMATCH[1]}"
        fi
    done < "$file"

    # A phase counts as complete when it has subtasks and none are open.
    local -A phase_done_by_num=()
    local pn
    for pn in "${!phase_total[@]}"; do
        if [[ "${phase_open[$pn]:-0}" -eq 0 ]]; then
            phase_done_by_num["$pn"]=1
        fi
    done

    # Walk pending subtasks in document order, deciding readiness.
    local ndjson="" blocked_ndjson="" ready_count=0 blocked_count=0
    local undeclared=0 first_pending_seen=0 i
    for (( i=0; i<${#t_ids[@]}; i++ )); do
        local id="${t_ids[$i]}" st="${t_status[$i]}"
        case "$st" in x|X|-|~) continue ;; esac

        local is_first_pending=0
        if [[ $first_pending_seen -eq 0 ]]; then
            is_first_pending=1
            first_pending_seen=1
        fi

        # Only the current phase can be dispatched — never roll across the boundary.
        if [[ -n "$current_phase" && "${t_phase[$i]}" != "$current_phase" ]]; then
            continue
        fi

        local deps="${t_deps[$i]}"
        local deps_trim="${deps#"${deps%%[![:space:]]*}"}"
        deps_trim="${deps_trim%"${deps_trim##*[![:space:]]}"}"

        local declared=1 ready=0 blocked_by=""

        if [[ -z "$deps_trim" ]] || [[ "$deps_trim" =~ ^\[.*\]$ ]]; then
            # Undeclared → cannot prove independence. Conservatively sequential:
            # only the document-first pending item is dispatchable. This is the
            # degradation path for legacy plans, and the reason --review now
            # requires the field on new ones.
            declared=0
            undeclared=$((undeclared + 1))
            [[ $is_first_pending -eq 1 ]] && ready=1
            blocked_by="undeclared dependencies"
        elif [[ "$deps_trim" =~ ^([Nn]one|N/A|n/a|-)$ ]]; then
            ready=1
        else
            ready=1
            local ref
            # Subtask refs: N.M
            for ref in $(grep -oE '[0-9]+\.[0-9]+' <<< "$deps_trim" || true); do
                if [[ -z "${resolved[$ref]:-}" ]]; then
                    ready=0
                    blocked_by+="Task $ref, "
                fi
            done
            # Phase refs: "Phase N complete". A reference to the task's OWN phase is
            # prose framing ("Phase 2 starts after Phase 1 complete"), not an edge —
            # treating it as one would deadlock every task against its own phase,
            # since its own phase is by definition incomplete while it is pending.
            local own_phase="${id%%.*}"
            for ref in $(grep -oiE '[Pp]hase[[:space:]]+[0-9]+' <<< "$deps_trim" | grep -oE '[0-9]+' || true); do
                [[ "$ref" == "$own_phase" ]] && continue
                if [[ -z "${phase_done_by_num[$ref]:-}" ]]; then
                    ready=0
                    blocked_by+="Phase $ref, "
                fi
            done
        fi

        if [[ $ready -eq 1 ]]; then
            if [[ $ready_count -lt 6 ]]; then
                ndjson+=$(jq -nc \
                    --arg task "$id" \
                    --arg text "${t_text[$i]}" \
                    --arg phase "${t_phase[$i]}" \
                    --arg deps "$deps_trim" \
                    --argjson declared "$( [[ $declared -eq 1 ]] && echo true || echo false )" \
                    '{task:$task, text:$text, phase:$phase, dependencies:$deps, deps_declared:$declared}')$'\n'
            fi
            ready_count=$((ready_count + 1))
        else
            blocked_ndjson+=$(jq -nc \
                --arg task "$id" \
                --arg deps "$deps_trim" \
                --arg blocked "${blocked_by%, }" \
                '{task:$task, dependencies:$deps, blocked_by:$blocked}')$'\n'
            blocked_count=$((blocked_count + 1))
        fi
    done

    local ready_json="[]" blocked_json="[]"
    [[ -n "$ndjson" ]] && ready_json=$(jq -sc '.' <<< "$ndjson")
    [[ -n "$blocked_ndjson" ]] && blocked_json=$(jq -sc '.' <<< "$blocked_ndjson")

    local deps_declared=true
    [[ $undeclared -gt 0 ]] && deps_declared=false

    # A pending phase where NOTHING is dispatchable is a dependency deadlock — a
    # cycle, or a dep on a later phase. Surfacing it here (rather than returning a
    # silently empty ready set) is what stops the executor from stalling with no
    # explanation; the blocked_items reasons name the exact edges to fix.
    local deadlock=false
    [[ $ready_count -eq 0 && $blocked_count -gt 0 ]] && deadlock=true

    printf '"ready_items": %s,\n  "ready_count": %d,\n  "blocked_items": %s,\n  "dependency_deadlock": %s,\n  "deps_declared": %s,\n  "deps_undeclared_count": %d' \
        "$ready_json" "$ready_count" "$blocked_json" "$deadlock" "$deps_declared" "$undeclared"
}

#------------------------------------------------------------------------------
# Parse PLN checkboxes and phases
#------------------------------------------------------------------------------

parse_progress() {
    local file="$1"

    local done_count=0
    local pending_count=0
    local skipped_count=0
    local total_count=0
    local current_phase=""
    local current_phase_done=0
    local current_phase_pending=0
    local next_items=""
    local next_count=0

    local in_phase=""

    # Per-phase tallies in document order. current_phase is resolved AFTER the
    # scan as the first phase (in order) that still has pending items, so a
    # fully-complete leading phase correctly advances the pointer to the next
    # incomplete phase. This is what the task-continue loop's phase-stop relies on.
    local -A phase_done=()
    local -A phase_pending=()
    local phase_order=()

    # Only checkboxes INSIDE a phase/step/stage/part section count as work items.
    # Scaffolding sections (Resources, Success Metrics, Approval, Risks, ...) use
    # checkboxes too but are NOT tasks — counting them inflates totals and stalls
    # the plan at <100%. Legacy plans with no phase headers fall back to counting
    # every checkbox (flat-checklist style).
    # The keyword must START the heading text (real phase headings are
    # "### Phase N: …"); this excludes Progress-log entries like
    # "### 2026-06-19 10:59 - Phase 1 (Tasks 1.1-1.3)" that merely mention a phase.
    local has_phases=0
    if grep -qE '^#{2,3}[[:space:]]+([Pp]hase|[Ss]tep|[Ss]tage|[Pp]art)([[:space:]]|:)' "$file" 2>/dev/null; then
        has_phases=1
    fi

    while IFS= read -r line; do
        # Detect section headers (## or ###). A phase/step/stage/part header opens
        # a countable section; any OTHER ##/### header (Context, Resources,
        # Success Metrics, Approval, ...) closes it, so trailing scaffolding
        # checkboxes are neither counted as tasks nor attributed to the last phase.
        # (#### Task headings are 4 hashes and don't match here, so a Task heading
        # never resets the section.)
        if [[ "$line" =~ ^#{2,3}[[:space:]]+(.+) ]]; then
            local phase_name="${BASH_REMATCH[1]}"
            if [[ "$phase_name" =~ ^([Pp]hase|[Ss]tep|[Ss]tage|[Pp]art)([[:space:]]|:) ]]; then
                in_phase="$phase_name"
                # Record phase in document order the first time we see it
                if [[ -z "${phase_done[$in_phase]:-}" ]]; then
                    phase_done["$in_phase"]=0
                    phase_pending["$in_phase"]=0
                    phase_order+=("$in_phase")
                fi
            else
                in_phase=""
            fi
        fi

        # A checkbox counts only inside a phase section — or anywhere, for legacy
        # plans with no phase headers at all.
        if [[ $has_phases -eq 1 && -z "$in_phase" ]]; then
            continue
        fi

        # Done: "- [x]/[X] ..." or "#### Task N: [x] ..."
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[xX]\][[:space:]](.+) ]] || \
           [[ "$line" =~ ^#{1,6}[[:space:]].*\[[xX]\][[:space:]](.+) ]]; then
            done_count=$((done_count + 1))
            total_count=$((total_count + 1))
            if [[ -n "$in_phase" ]]; then
                phase_done["$in_phase"]=$(( ${phase_done[$in_phase]:-0} + 1 ))
            fi
            continue
        fi

        # Skipped / deferred / cancelled: "- [-]/[~] ..." or "#### Task N: [-] ..."
        # These are decided (not outstanding work) — tracked separately so they
        # don't read as pending and don't block plan/phase completion.
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[-~]\][[:space:]](.+) ]] || \
           [[ "$line" =~ ^#{1,6}[[:space:]].*\[[-~]\][[:space:]](.+) ]]; then
            skipped_count=$((skipped_count + 1))
            total_count=$((total_count + 1))
            continue
        fi

        # Pending: "- [ ] ..." or "#### Task N: [ ] ..."
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]](.+) ]] || \
           [[ "$line" =~ ^#{1,6}[[:space:]].*\[[[:space:]]\][[:space:]](.+) ]]; then
            pending_count=$((pending_count + 1))
            total_count=$((total_count + 1))

            if [[ -n "$in_phase" ]]; then
                phase_pending["$in_phase"]=$(( ${phase_pending[$in_phase]:-0} + 1 ))
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

    # Resolve current_phase: first phase in document order with pending items.
    # If every phase is complete, fall back to the last phase seen (so output
    # still reports a sensible phase for a finished plan).
    local p
    for p in "${phase_order[@]}"; do
        if [[ "${phase_pending[$p]:-0}" -gt 0 ]]; then
            current_phase="$p"
            break
        fi
    done
    if [[ -z "$current_phase" ]] && [[ ${#phase_order[@]} -gt 0 ]]; then
        current_phase="${phase_order[${#phase_order[@]}-1]}"
    fi
    if [[ -n "$current_phase" ]]; then
        current_phase_done="${phase_done[$current_phase]:-0}"
        current_phase_pending="${phase_pending[$current_phase]:-0}"
    fi

    # Determine progress percentage
    local percent=0
    if [[ $total_count -gt 0 ]]; then
        # Resolved = done + skipped/deferred/cancelled (decided, not outstanding),
        # so a plan with nothing pending reads as 100%.
        percent=$(( ((done_count + skipped_count) * 100) / total_count ))
    fi

    # Build JSON output
    local next_action="continue_implementation"
    local message="$done_count done, $pending_count left"
    if [[ $skipped_count -gt 0 ]]; then
        message="$message, $skipped_count skipped"
    fi
    message="$message ($percent%)"
    if [[ $pending_count -eq 0 ]]; then
        next_action="display_summary"
        if [[ $skipped_count -gt 0 ]]; then
            message="All work resolved — $done_count done, $skipped_count skipped"
        else
            message="All $done_count tasks complete"
        fi
    fi

    # Keep the unescaped heading for string comparison in compute_ready_items
    local current_phase_raw="$current_phase"

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

    # Dependency-aware ready set (empty when nothing is pending)
    local ready_fragment=""
    if [[ $pending_count -gt 0 ]]; then
        local ready_data
        ready_data=$(compute_ready_items "$file" "$current_phase_raw")
        ready_fragment=",
  $ready_data"
        # A deadlock is not "continue implementation" — the plan needs an edit first.
        if [[ "$ready_data" == *'"dependency_deadlock": true'* ]]; then
            next_action="resolve_dependency_deadlock"
            message="$message — BLOCKED: no dispatchable subtask, see blocked_items"
        fi
    fi

    output_json "success" "$next_action" "$message" \
        "\"plan_file\": \"$file\",
  \"progress\": {
    \"done\": $done_count,
    \"pending\": $pending_count,
    \"skipped\": $skipped_count,
    \"total\": $total_count,
    \"percent\": $percent
  },
  \"current_phase\": \"$current_phase\",
  \"phase_progress\": {
    \"done\": $current_phase_done,
    \"pending\": $current_phase_pending,
    \"total\": $((current_phase_done + current_phase_pending))
  },
  \"next_items\": [$next_items]${ready_fragment}${config_fragment}"
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
                work_model=$(trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            elif [[ "$line" =~ ^-[[:space:]]\*\*Test\ Model\*\*:[[:space:]]*(.+) ]]; then
                test_model=$(trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            elif [[ "$line" =~ ^-[[:space:]]\*\*TDD\ Required\*\*:[[:space:]]*(.+) ]]; then
                tdd_required=$(trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            elif [[ "$line" =~ ^-[[:space:]]\*\*Auto\ Review\*\*:[[:space:]]*(.+) ]]; then
                auto_review=$(trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            elif [[ "$line" =~ ^-[[:space:]]\*\*Review\ Type\*\*:[[:space:]]*(.+) ]]; then
                review_type=$(trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            elif [[ "$line" =~ ^-[[:space:]]\*\*Fresh\ Context\*\*:[[:space:]]*(.+) ]]; then
                fresh_context=$(trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
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
    local section_line=""
    # Ask whether the section exists as a QUESTION (grep -q as a condition,
    # which is what it is for) instead of running the pipeline and then
    # suppressing its status. Nothing is hidden: a real grep failure still
    # surfaces, and "absent" is answered before we try to locate a line number.
    if grep -q "^## Progress & Lessons Learned" "$file"; then
        section_line=$(grep -n "^## Progress & Lessons Learned" "$file" | head -1 | cut -d: -f1)
    fi

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
# Extract Task Detail (--task-detail N.M[,N.M...])
#------------------------------------------------------------------------------

# Emit the full field block for one or more "#### Task N.M" headings as JSON,
# so the orchestrator can build subagent dispatch prompts without ever
# Reading the PLN file itself.
extract_task_detail() {
    local file="$1"
    local wanted_csv="$2"

    local -A wanted=()
    local _w
    IFS=',' read -ra _wanted_arr <<< "$wanted_csv"
    for _w in "${_wanted_arr[@]}"; do
        _w=$(trim "$_w")
        [[ -n "$_w" ]] && wanted["$_w"]=1
    done

    local tasks="[]"
    local cur_id="" cur_matches=0
    local cur_heading_text="" cur_ac_csv=""
    local cur_description="" cur_estimated_time="" cur_complexity=""
    local -a cur_files=()
    local seen_blank=0

    flush_task() {
        if [[ -z "$cur_id" ]] || [[ $cur_matches -eq 0 ]]; then
            return
        fi
        local files_json="[]"
        if [[ ${#cur_files[@]} -gt 0 ]]; then
            files_json=$(printf '%s\n' "${cur_files[@]}" | jq -R . | jq -s .)
        fi
        local ac_json="[]"
        if [[ -n "$cur_ac_csv" ]]; then
            ac_json=$(printf '%s\n' "${cur_ac_csv//,/$'\n'}" | jq -R . | jq -s .)
        fi
        local entry
        entry=$(jq -n \
            --arg task "$cur_id" \
            --arg description "$cur_description" \
            --argjson files "$files_json" \
            --argjson acceptance_criteria "$ac_json" \
            --arg estimated_time "$cur_estimated_time" \
            --arg complexity "$cur_complexity" \
            --arg heading "$cur_heading_text" \
            '{task: $task, heading: $heading, description: $description, files: $files, acceptance_criteria: $acceptance_criteria, estimated_time: $estimated_time, complexity: $complexity}')
        tasks=$(echo "$tasks" | jq --argjson e "$entry" '. + [$e]')
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^####[[:space:]]+Task[[:space:]]+([0-9]+(\.[0-9]+)*):[[:space:]]*\[(.)\][[:space:]]*(.*) ]]; then
            flush_task
            cur_id="${BASH_REMATCH[1]}"
            local rest="${BASH_REMATCH[4]}"
            cur_matches=0
            [[ -n "${wanted[$cur_id]:-}" ]] && cur_matches=1
            cur_ac_csv=""
            # Pull [AC#] / [ACx] tags out of the heading remainder
            while [[ "$rest" =~ \[(AC[0-9x]*)\] ]]; do
                if [[ -z "$cur_ac_csv" ]]; then
                    cur_ac_csv="${BASH_REMATCH[1]}"
                else
                    cur_ac_csv="${cur_ac_csv},${BASH_REMATCH[1]}"
                fi
                rest="${rest/\[${BASH_REMATCH[1]}\]/}"
            done
            cur_heading_text=$(trim "$rest")
            cur_description=""
            cur_estimated_time=""
            cur_complexity=""
            cur_files=()
            seen_blank=0
            continue
        fi

        if [[ -z "$cur_id" ]] || [[ $cur_matches -eq 0 ]]; then
            continue
        fi

        # Blank line closes the field block for this task (same contract as
        # compute_ready_items above)
        if [[ -z "${line// /}" ]]; then
            seen_blank=1
            continue
        fi
        [[ $seen_blank -eq 1 ]] && continue

        if [[ "$line" =~ ^-[[:space:]]+\*\*Description\*\*:[[:space:]]*(.*) ]]; then
            cur_description="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]+\*\*Files\*\*:[[:space:]]*(.*) ]]; then
            local files_raw="${BASH_REMATCH[1]}"
            IFS=',' read -ra _files_arr <<< "$files_raw"
            local _f
            for _f in "${_files_arr[@]}"; do
                _f=$(trim "$_f" | tr -d '`')
                [[ -n "$_f" ]] && cur_files+=("$_f")
            done
        elif [[ "$line" =~ ^-[[:space:]]+\*\*Estimated\ Time\*\*:[[:space:]]*(.*) ]]; then
            cur_estimated_time="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]+\*\*Complexity\*\*:[[:space:]]*(.*) ]]; then
            cur_complexity="${BASH_REMATCH[1]}"
        fi
    done < "$file"
    flush_task

    log_json "$tasks"
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
                _at_key=$(trim "$_at_key")
                _at_val=$(trim "$_at_val")
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
        --task-detail) TASK_DETAIL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] [--file <path>] [--mark-complete \"<item>\" ...] [--actual-time \"1.1=45m\"] [--progress \"note\"] [--lessons \"text\"] [--task-label \"Task 1.2\"] [--went-well \"...\"] [--challenges \"...\"] [--differently \"...\"] [--patterns \"...\"] [--extract-entries] [--task-detail \"1.1,1.2\"]"
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

# Task detail mode — output JSON and exit
if [[ -n "$TASK_DETAIL" ]]; then
    extract_task_detail "$PLN_PATH" "$TASK_DETAIL"
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

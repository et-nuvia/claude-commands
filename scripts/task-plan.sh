#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Plan implementation with Opus-powered analysis
#
# Usage:
#   ~/.claude/scripts/plan-implementation.sh [--json|--raw] [--full|--section] [--source <path|url|description>]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags:
#   --load:        Load and parse requirements from source
#   --analyze:     Analyze codebase context (USE OPUS)
#   --breakdown:   Break down into subtasks (USE OPUS)
#   --estimate:    Estimate complexity and risks
#   --generate:    Generate implementation plan document
#   --review:      Validate PLN document quality before execution
#   --full:        Run all sections end-to-end (default)
#
# Flags:
#   --skip-review: Bypass PLN quality validation
#
# Arguments:
#   source:  Optional requirement source (task doc path, issue number, or description)
#
# Workflow:
#   1. LLM calls: plan-implementation.sh --json --full [source]
#   2. Script returns: {"status":"ready_for_opus", "requirements":{...}}
#   3. LLM must use Opus to continue with analysis
#   4. Or returns complete plan if successful

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (must be defined BEFORE sourcing)
map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        ready_for_opus)       echo "use_opus_model" ;;
        requires_opus)        echo "use_opus_model" ;;
        ready_for_generation) echo "generate_plan" ;;
        review_passed)        echo "continue" ;;
        review_failed)        echo "fix_plan" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

# Source shared output framework
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"
SOURCE=""
SKIP_REVIEW=false
REVIEW_FILE=""
REQUIREMENTS_DATA=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Load requirements from source
section_load() {
    log "${BLUE}Loading Requirements${NC}"

    # Determine source type and load
    if [[ -z "$SOURCE" ]]; then
        local ct_source="" branch_source="" branch_task_id=""

        # Try .current-task file
        if [[ -f ".current-task" ]]; then
            ct_source=$(jq -r '.task_doc // empty' .current-task 2>/dev/null || echo "")
            [[ -n "$ct_source" && ! -f "$ct_source" ]] && ct_source=""
        fi

        # Try extracting task ID from branch name (feature/XXXXXX-slug or bugfix/XXXXXX-slug)
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$current_branch" =~ ^(feature|bugfix)/([A-Fa-f0-9]{6})- ]]; then
            branch_task_id="${BASH_REMATCH[2]}"
            branch_task_id=$(echo "$branch_task_id" | tr '[:lower:]' '[:upper:]')
            # Search for TSK document matching this task ID
            local docs_dir
            docs_dir=$(find docs/active -name "${branch_task_id}-*-TSK-*" 2>/dev/null | head -1)
            [[ -n "$docs_dir" && -f "$docs_dir" ]] && branch_source="$docs_dir"
        fi

        # Resolve: both found but different → conflict, ask user
        if [[ -n "$ct_source" && -n "$branch_source" ]]; then
            local ct_id branch_id
            ct_id=$(basename "$ct_source" | cut -c1-6)
            branch_id=$(basename "$branch_source" | cut -c1-6)
            if [[ "$ct_id" != "$branch_id" ]]; then
                # Conflict: .current-task points to a different task than the branch
                exit_with_json "error" "Task conflict: .current-task points to ${ct_id} but branch suggests ${branch_id}" \
                    "Resolve by providing --source explicitly or updating .current-task" \
                    "\"current_task_source\": \"$ct_source\", \"branch_source\": \"$branch_source\", \"reason\": \"task_conflict\""
            fi
        fi

        # Use whichever was found (.current-task preferred)
        if [[ -n "$ct_source" ]]; then
            SOURCE="$ct_source"
            log "${GREEN}✓${NC} Auto-detected source from .current-task: $(basename "$SOURCE")"
        elif [[ -n "$branch_source" ]]; then
            SOURCE="$branch_source"
            log "${GREEN}✓${NC} Auto-detected source from branch name: $(basename "$SOURCE")"
        fi

        # Still empty — error out
        if [[ -z "$SOURCE" ]]; then
            if [[ "$SECTION" == "load" ]]; then
                exit_with_json "error" "No source provided" "Provide --source with task doc path, issue number, or feature description" \
                    '"input_needed": "source"'
            fi
            exit_with_json "error" "No source provided" "Provide --source <path|url|description> or run from a directory with .current-task"
        fi
    fi

    # Parse source type
    local source_type="unknown"
    local source_data=""
    local dsn_doc="" dsn_data=""
    local inv_doc="" inv_data=""
    local arc_doc="" plan_notes_present="false"

    if [[ -f "$SOURCE" ]]; then
        # File path - read task document
        source_type="task_document"
        if ! source_data=$(cat "$SOURCE" 2>&1); then
            exit_with_json "error" "Failed to read task document" "$source_data"
        fi
        log "${GREEN}✓${NC} Loaded task document: $SOURCE"
        # Check for DSN (Design) document for this task
        local task_id_match
        task_id_match=$(basename "$SOURCE" | grep -oE '^[A-Fa-f0-9]{6}' || echo "")
        if [[ -n "$task_id_match" ]]; then
            dsn_doc=$(find "$(dirname "$SOURCE")" -name "${task_id_match}-*-DSN-*.md" 2>/dev/null | sort -r | head -1 || echo "")
            if [[ -n "$dsn_doc" ]] && [[ -f "$dsn_doc" ]]; then
                dsn_data=$(cat "$dsn_doc" 2>/dev/null || echo "")
                log "${GREEN}✓${NC} Found design document: $(basename "$dsn_doc")"
            fi
            # Check for an INV (investigation report) — for investigation-driven
            # tasks it carries the confirmed root cause the plan must build on.
            inv_doc=$(find "$(dirname "$SOURCE")" -name "${task_id_match}-*-INV-*.md" 2>/dev/null | sort -r | head -1 || echo "")
            if [[ -n "$inv_doc" ]] && [[ -f "$inv_doc" ]]; then
                inv_data=$(cat "$inv_doc" 2>/dev/null || echo "")
                log "${GREEN}✓${NC} Found investigation report: $(basename "$inv_doc")"
            fi
        fi
        # ARC linkage (advisory, never blocks): /feature-to-task writes a
        # "## Related ARC" reference and a "## Notes for /task-plan" section
        # (suggested phase structure + test-prep gaps) into ARC-derived TSKs.
        arc_doc=$(grep -oE '[^ `"()]*-ARC-[^ `"()]*\.md' "$SOURCE" 2>/dev/null | head -1 || echo "")
        if [[ -n "$arc_doc" ]]; then
            if [[ -f "$arc_doc" ]]; then
                log "${GREEN}✓${NC} Found linked ARC document: $(basename "$arc_doc")"
            else
                log "${YELLOW}⚠${NC} TSK references ARC but file not found: $arc_doc"
                arc_doc=""
            fi
        fi
        grep -qE '^##[[:space:]]+Notes for /task-plan' "$SOURCE" 2>/dev/null && plan_notes_present="true"
    elif [[ "$SOURCE" =~ ^#?[0-9]+$ ]]; then
        # Issue number
        source_type="issue_number"
        source_data="$SOURCE"
        log "${GREEN}✓${NC} Will fetch issue: $SOURCE"
    elif [[ "$SOURCE" =~ ^https?:// ]]; then
        # URL - assume issue URL
        source_type="issue_url"
        source_data="$SOURCE"
        log "${GREEN}✓${NC} Will fetch issue from URL: $SOURCE"
    else
        # Free-form description
        source_type="description"
        source_data="$SOURCE"
        log "${GREEN}✓${NC} Using feature description"
    fi

    # ADR list (gated: empty array when docs/adr/ doesn't exist)
    local adr_files_json="[]"
    if [[ -d "docs/adr" ]]; then
        adr_files_json=$(find "docs/adr" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | sort | jq -R . | jq -sc . 2>/dev/null || echo "[]")
    fi

    REQUIREMENTS_DATA=$(jq -n \
        --arg type "$source_type" \
        --arg data "$source_data" \
        --arg dsn_doc "${dsn_doc:-}" \
        --arg dsn_data "${dsn_data:-}" \
        --arg inv_doc "${inv_doc:-}" \
        --arg inv_data "${inv_data:-}" \
        --arg arc_doc "${arc_doc:-}" \
        --argjson plan_notes_present "$plan_notes_present" \
        --argjson adr_files "$adr_files_json" \
        '{source_type: $type, source_data: $data, dsn_doc: (if $dsn_doc == "" then null else $dsn_doc end), dsn_data: (if $dsn_data == "" then null else $dsn_data end), inv_doc: (if $inv_doc == "" then null else $inv_doc end), inv_data: (if $inv_data == "" then null else $inv_data end), arc_doc: (if $arc_doc == "" then null else $arc_doc end), plan_notes_present: $plan_notes_present, adr_files: $adr_files}')

    if [[ "$SECTION" == "load" ]]; then
        exit_with_json "success" "Requirements loaded" "" \
            '"requirements": '"$REQUIREMENTS_DATA"
    fi
}

# Section 2: Analyze codebase context (REQUIRES OPUS)
section_analyze() {
    log "${BLUE}Analyzing Codebase Context${NC}"

    # This section MUST be run by Opus model
    # Script returns status indicating Opus is required

    # Check for PROJECT.yaml
    if [[ ! -f "PROJECT.yaml" ]]; then
        log "${YELLOW}⚠${NC} PROJECT.yaml not found - will need to detect structure"
    fi

    # Collect project structure info
    local project_info=""
    if [[ -f "PROJECT.yaml" ]]; then
        project_info=$(cat PROJECT.yaml)
    fi

    if [[ "$SECTION" == "analyze" ]]; then
        exit_with_json "ready_for_opus" "Codebase analysis requires Opus model" \
            "LLM must use model: opus for this section" \
            '"project_info": '"$(echo "$project_info" | jq -Rs .)"
    fi

    log "${GREEN}✓${NC} Project context collected"
}

# Section 3: Break down into subtasks (REQUIRES OPUS)
section_breakdown() {
    log "${BLUE}Breaking Down Into Subtasks${NC}"

    # This section MUST be run by Opus model
    # Script provides framework but Opus does the analysis

    if [[ "$SECTION" == "breakdown" ]]; then
        exit_with_json "ready_for_opus" "Task breakdown requires Opus model" \
            "LLM must use model: opus to analyze architecture and create subtasks"
    fi

    log "${GREEN}✓${NC} Ready for task breakdown"
}

# Section 4: Estimate complexity
section_estimate() {
    log "${BLUE}Estimating Complexity${NC}"

    # Provide estimation guidelines
    local guidelines=$(cat <<'GUIDELINES'
T-shirt sizing:
- XS (< 30 min): Simple changes
- S (30 min - 2 hours): Straightforward tasks
- M (2-4 hours): Moderate complexity
- L (4-8 hours): Complex features
- XL (1-2 days): Very complex features
GUIDELINES
)

    if [[ "$SECTION" == "estimate" ]]; then
        exit_with_json "ready_for_opus" "Complexity estimation requires analysis" \
            "Opus model needed to evaluate task complexity" \
            '"guidelines": '"$(echo "$guidelines" | jq -Rs .)"
    fi

    log "${GREEN}✓${NC} Estimation guidelines ready"
}

# Section 5: Generate plan document
section_generate() {
    log "${BLUE}Generating Plan Document${NC}"

    # Check for template
    local template_path="$HOME/.claude/templates/implementation-plan.md"
    if [[ ! -f "$template_path" ]]; then
        log "${YELLOW}⚠${NC} Template not found at $template_path"
    fi

    # LLM should use EnterPlanMode or directly create plan
    if [[ "$SECTION" == "generate" ]]; then
        exit_with_json "ready_for_generation" "Plan generation requires LLM with context" \
            "LLM should create plan document with all analysis results"
    fi

    log "${GREEN}✓${NC} Ready for plan generation"
}

# Section 6: Review PLN document quality
section_review() {
    log "${BLUE}Reviewing Plan Quality${NC}"

    # Skip review if flag set
    if [[ "$SKIP_REVIEW" == true ]]; then
        log "${YELLOW}⚠${NC} Review skipped (--skip-review)"
        exit_with_json "review_passed" "Review skipped by user request" ""
    fi

    # Determine PLN file to review
    local pln_file="$REVIEW_FILE"
    if [[ -z "$pln_file" ]] && [[ -n "$SOURCE" ]] && [[ -f "$SOURCE" ]]; then
        # If source is a task doc, find its PLN
        local task_id_match
        task_id_match=$(basename "$SOURCE" | grep -oE '^[A-Fa-f0-9]{6}' || echo "")
        if [[ -n "$task_id_match" ]]; then
            pln_file=$(find "$(dirname "$SOURCE")" -name "${task_id_match}-*-PLN-*.md" 2>/dev/null | sort -r | head -1 || echo "")
        fi
    fi

    if [[ -z "$pln_file" ]] || [[ ! -f "$pln_file" ]]; then
        exit_with_json "error" "No PLN file found to review" \
            "Provide --source with task doc or use --review with a PLN path via --source"
    fi

    log "${GREEN}✓${NC} Reviewing: $(basename "$pln_file")"

    # Collect issues as newline-delimited JSON objects (one jq call at end)
    local issues_ndjson=""

    # Helper to append an issue
    _add_issue() {
        local check="$1" task="$2" msg="$3" line="$4"
        issues_ndjson+=$(jq -nc --arg c "$check" --arg t "$task" --arg m "$msg" --argjson l "$line" \
            '{check:$c, task:$t, message:$m, line:$l}')$'\n'
    }

    # Read entire PLN into an array for indexed access
    local -a pln_lines=()
    while IFS= read -r line; do
        pln_lines+=("$line")
    done < "$pln_file"
    local total_lines=${#pln_lines[@]}

    # ── Check 0: Coverage verification against TSK and DSN ──
    # Find the TSK and DSN documents for this task
    local task_id_match
    task_id_match=$(basename "$pln_file" | grep -oE '^[A-Fa-f0-9]{6}' || echo "")
    local pln_dir
    pln_dir=$(dirname "$pln_file")

    if [[ -n "$task_id_match" ]]; then
        # Find TSK document
        local tsk_file
        tsk_file=$(find "$pln_dir" -name "${task_id_match}-*-TSK-*.md" 2>/dev/null | sort -r | head -1 || echo "")

        if [[ -n "$tsk_file" ]] && [[ -f "$tsk_file" ]]; then
            log "${GREEN}✓${NC} Found TSK: $(basename "$tsk_file")"

            # Extract unchecked requirements from TSK (lines matching "- [ ] ")
            local tsk_requirements=()
            while IFS= read -r req_line; do
                # Strip the checkbox prefix and leading/trailing whitespace
                local req_text
                req_text=$(echo "$req_line" | sed 's/^[[:space:]]*- \[ \] //' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                if [[ -n "$req_text" ]]; then
                    tsk_requirements+=("$req_text")
                fi
            done < <(grep -E '^\s*- \[ \]' "$tsk_file" 2>/dev/null || true)

            local pln_content
            pln_content=$(cat "$pln_file")

            # Check each TSK requirement has some mention in the PLN
            # Strategy: extract multiple keywords from the requirement, match if
            # ANY 2+ significant keywords appear in the plan (fuzzy matching).
            local unmatched_reqs=()
            for req in "${tsk_requirements[@]}"; do
                # Strip markdown formatting and extract significant words (4+ chars, no stopwords)
                local keywords
                keywords=$(echo "$req" | sed 's/`//g; s/\*\*//g; s/[(){}[\]]//g' | \
                    tr '[:upper:]' '[:lower:]' | tr -s ' ' '\n' | \
                    grep -vE '^(the|and|for|with|from|this|that|into|have|been|will|should|must|also|only|each|both|all|add|use|set|run|get|new|can|not|its|has|are|was|may|but|our|any|via|per|to|in|on|at|of|is|or|a|an|if|no|do|be|as|by)$' | \
                    grep -E '.{4,}' | head -8 || echo "")

                local match_count=0
                local pln_lower
                pln_lower=$(echo "$pln_content" | tr '[:upper:]' '[:lower:]')
                while IFS= read -r kw; do
                    [[ -z "$kw" ]] && continue
                    # Try exact match first, then stem match (strip common suffixes)
                    if echo "$pln_lower" | grep -qF -- "$kw"; then
                        match_count=$((match_count + 1))
                    else
                        # Simple suffix stemming: strip ing/ed/tion/ment/able/ness/ity/ies/ying
                        local stem
                        stem=$(echo "$kw" | sed -E 's/(ating|ting|ing|ment|tion|sion|able|ible|ness|ity|ies|ied|ying)$//')
                        if [[ ${#stem} -ge 4 ]] && echo "$pln_lower" | grep -qF -- "$stem"; then
                            match_count=$((match_count + 1))
                        fi
                    fi
                done <<< "$keywords"

                # Require at least 2 keyword matches (or 1 if only 1-2 keywords extracted)
                local keyword_count
                keyword_count=$(echo "$keywords" | grep -c '.' || echo 0)
                local threshold=2
                [[ $keyword_count -le 2 ]] && threshold=1

                if [[ $match_count -lt $threshold ]]; then
                    unmatched_reqs+=("$req")
                fi
            done

            if [[ ${#unmatched_reqs[@]} -gt 0 ]]; then
                for unmatched in "${unmatched_reqs[@]}"; do
                    _add_issue "tsk_coverage" "TSK requirement" \
                        "TSK requirement not found in plan: ${unmatched:0:120}" 0
                done
                log "${YELLOW}⚠${NC} ${#unmatched_reqs[@]} TSK requirement(s) may not be covered in the plan"
            else
                log "${GREEN}✓${NC} All ${#tsk_requirements[@]} TSK requirements appear covered"
            fi
        fi

        # Find DSN document
        local dsn_file
        dsn_file=$(find "$pln_dir" -name "${task_id_match}-*-DSN-*.md" 2>/dev/null | sort -r | head -1 || echo "")

        if [[ -n "$dsn_file" ]] && [[ -f "$dsn_file" ]]; then
            log "${GREEN}✓${NC} Found DSN: $(basename "$dsn_file")"

            # Extract design decisions from DSN (### Decision N: Title lines)
            local dsn_decisions=()
            while IFS= read -r dec_line; do
                local dec_title
                dec_title=$(echo "$dec_line" | sed 's/^###[[:space:]]*Decision[[:space:]]*[0-9]*:[[:space:]]*//')
                if [[ -n "$dec_title" ]]; then
                    dsn_decisions+=("$dec_title")
                fi
            done < <(grep -E '^###[[:space:]]+Decision[[:space:]]+[0-9]+:' "$dsn_file" 2>/dev/null || true)

            local pln_content
            pln_content=$(cat "$pln_file")

            # Check each DSN decision has some mention in the PLN
            # Strategy: extract keywords from both sides of the dash in decision titles,
            # match if ANY 2+ significant keywords appear in the plan.
            local unmatched_decisions=()
            for dec in "${dsn_decisions[@]}"; do
                local dec_keywords
                dec_keywords=$(echo "$dec" | sed 's/`//g; s/\*\*//g; s/[(){}[\]]//g; s/[—–]/ /g' | \
                    tr '[:upper:]' '[:lower:]' | tr -s ' ' '\n' | \
                    grep -vE '^(the|and|for|with|from|this|that|into|have|been|will|should|must|also|only|each|both|all|add|use|set|run|get|new|can|not|its|has|are|was|may|but|our|any|via|per|to|in|on|at|of|is|or|a|an|if|no|do|be|as|by|design|needed)$' | \
                    grep -E '.{3,}' | head -8 || echo "")

                local dec_match_count=0
                local pln_lower
                pln_lower=$(echo "$pln_content" | tr '[:upper:]' '[:lower:]')
                while IFS= read -r kw; do
                    [[ -z "$kw" ]] && continue
                    if echo "$pln_lower" | grep -qF -- "$kw"; then
                        dec_match_count=$((dec_match_count + 1))
                    else
                        local stem
                        stem=$(echo "$kw" | sed -E 's/(ating|ting|ing|ment|tion|sion|able|ible|ness|ity|ies|ied|ying)$//')
                        if [[ ${#stem} -ge 3 ]] && echo "$pln_lower" | grep -qF -- "$stem"; then
                            dec_match_count=$((dec_match_count + 1))
                        fi
                    fi
                done <<< "$dec_keywords"

                local dec_kw_count
                dec_kw_count=$(echo "$dec_keywords" | grep -c '.' || echo 0)
                local dec_threshold=2
                [[ $dec_kw_count -le 2 ]] && dec_threshold=1

                if [[ $dec_match_count -lt $dec_threshold ]]; then
                    unmatched_decisions+=("$dec")
                fi
            done

            if [[ ${#unmatched_decisions[@]} -gt 0 ]]; then
                for unmatched in "${unmatched_decisions[@]}"; do
                    _add_issue "dsn_coverage" "DSN decision" \
                        "DSN design decision not reflected in plan: ${unmatched:0:120}" 0
                done
                log "${YELLOW}⚠${NC} ${#unmatched_decisions[@]} DSN decision(s) may not be reflected in the plan"
            else
                log "${GREEN}✓${NC} All ${#dsn_decisions[@]} DSN decisions appear covered"
            fi

            # ── Check 0b: Deferred Decisions coverage ──
            # Each "### Deferred N: Title" in the DSN must map to an
            # investigation subtask in the plan (the deferred list drives
            # Phase 1 planning). A plan that silently drops deferred
            # decisions skips the investigation phase entirely.
            local dsn_deferred=()
            while IFS= read -r def_line; do
                local def_title
                def_title=$(echo "$def_line" | sed 's/^###[[:space:]]*Deferred[[:space:]]*[0-9]*:[[:space:]]*//')
                if [[ -n "$def_title" ]]; then
                    dsn_deferred+=("$def_title")
                fi
            done < <(grep -E '^###[[:space:]]+Deferred[[:space:]]+[0-9]+:' "$dsn_file" 2>/dev/null || true)

            if [[ ${#dsn_deferred[@]} -gt 0 ]]; then
                local unmatched_deferred=()
                for def in "${dsn_deferred[@]}"; do
                    local def_keywords
                    def_keywords=$(echo "$def" | sed 's/`//g; s/\*\*//g; s/[(){}[\]]//g; s/[—–]/ /g' | \
                        tr '[:upper:]' '[:lower:]' | tr -s ' ' '\n' | \
                        grep -vE '^(the|and|for|with|from|this|that|into|have|been|will|should|must|also|only|each|both|all|add|use|set|run|get|new|can|not|its|has|are|was|may|but|our|any|via|per|to|in|on|at|of|is|or|a|an|if|no|do|be|as|by|design|needed)$' | \
                        grep -E '.{3,}' | head -8 || echo "")

                    local def_match_count=0
                    local pln_lower
                    pln_lower=$(echo "$pln_content" | tr '[:upper:]' '[:lower:]')
                    while IFS= read -r kw; do
                        [[ -z "$kw" ]] && continue
                        if echo "$pln_lower" | grep -qF -- "$kw"; then
                            def_match_count=$((def_match_count + 1))
                        else
                            local stem
                            stem=$(echo "$kw" | sed -E 's/(ating|ting|ing|ment|tion|sion|able|ible|ness|ity|ies|ied|ying)$//')
                            if [[ ${#stem} -ge 3 ]] && echo "$pln_lower" | grep -qF -- "$stem"; then
                                def_match_count=$((def_match_count + 1))
                            fi
                        fi
                    done <<< "$def_keywords"

                    local def_kw_count
                    def_kw_count=$(echo "$def_keywords" | grep -c '.' || echo 0)
                    local def_threshold=2
                    [[ $def_kw_count -le 2 ]] && def_threshold=1

                    if [[ $def_match_count -lt $def_threshold ]]; then
                        unmatched_deferred+=("$def")
                    fi
                done

                if [[ ${#unmatched_deferred[@]} -gt 0 ]]; then
                    for unmatched in "${unmatched_deferred[@]}"; do
                        _add_issue "dsn_deferred_coverage" "DSN deferred decision" \
                            "DSN deferred decision has no investigation subtask in plan: ${unmatched:0:120}" 0
                    done
                    log "${YELLOW}⚠${NC} ${#unmatched_deferred[@]} DSN deferred decision(s) have no investigation subtask"
                else
                    log "${GREEN}✓${NC} All ${#dsn_deferred[@]} DSN deferred decisions map to plan subtasks"
                fi
            fi
        fi
    fi

    # Find all task heading line numbers
    local -a task_starts=()
    local -a task_ids=()
    for (( i=0; i<total_lines; i++ )); do
        if [[ "${pln_lines[$i]}" =~ ^####[[:space:]]+Task[[:space:]]+([0-9]+\.[0-9]+) ]]; then
            task_starts+=("$i")
            task_ids+=("${BASH_REMATCH[1]}")
        fi
    done

    # Index every declared task id + phase number, so dependency refs can be
    # validated as pointing at something that actually exists in this plan.
    local -A known_task_ids=()
    local -A known_phases=()
    local _tid
    for _tid in "${task_ids[@]}"; do
        known_task_ids["$_tid"]=1
        known_phases["${_tid%%.*}"]=1
    done

    # Process each task block
    for (( t=0; t<${#task_starts[@]}; t++ )); do
        local start=${task_starts[$t]}
        local task_id="${task_ids[$t]}"
        local heading="${pln_lines[$start]}"
        local heading_line=$((start + 1))  # 1-based line number

        # Determine block end (next task heading or next ## heading)
        local end=$total_lines
        for (( j=start+1; j<total_lines; j++ )); do
            if [[ "${pln_lines[$j]}" =~ ^####[[:space:]]+Task || "${pln_lines[$j]}" =~ ^###[[:space:]] || "${pln_lines[$j]}" =~ ^##[[:space:]] ]]; then
                end=$j
                break
            fi
        done

        # Check 1: Acceptance criteria tags [AC#]
        if ! echo "$heading" | grep -qE '\[AC[0-9x]+\]'; then
            _add_issue "acceptance_criteria" "Task $task_id" \
                "Missing [AC#] tag — subtask has no acceptance criteria traceability" "$heading_line"
        fi

        # Extract metadata fields from block
        local est_time="" tdd_req="" auto_rev="" rev_type="" fresh_ctx="" deps=""
        for (( j=start+1; j<end; j++ )); do
            local bline="${pln_lines[$j]}"
            if [[ "$bline" =~ ^-[[:space:]]+\*\*Estimated\ Time\*\*:[[:space:]]*(.*) ]]; then
                est_time="${BASH_REMATCH[1]}"
            elif [[ "$bline" =~ ^-[[:space:]]+\*\*TDD\ Required\*\*:[[:space:]]*(.*) ]]; then
                tdd_req="${BASH_REMATCH[1]}"
            elif [[ "$bline" =~ ^-[[:space:]]+\*\*Auto\ Review\*\*:[[:space:]]*(.*) ]]; then
                auto_rev="${BASH_REMATCH[1]}"
            elif [[ "$bline" =~ ^-[[:space:]]+\*\*Review\ Type\*\*:[[:space:]]*(.*) ]]; then
                rev_type="${BASH_REMATCH[1]}"
            elif [[ "$bline" =~ ^-[[:space:]]+\*\*Fresh\ Context\*\*:[[:space:]]*(.*) ]]; then
                fresh_ctx="${BASH_REMATCH[1]}"
            elif [[ "$bline" =~ ^-[[:space:]]+\*\*Dependencies\*\*:[[:space:]]*(.*) ]]; then
                deps="${BASH_REMATCH[1]}"
            fi
        done

        # Check 2: Subtask size — warn if estimated time exceeds complexity-appropriate threshold
        # XS/S: 30m, M: 2h, L: 4h, XL: 8h
        if [[ -n "$est_time" ]]; then
            local minutes=0
            if [[ "$est_time" =~ ([0-9]+)h ]]; then
                minutes=$(( ${BASH_REMATCH[1]} * 60 ))
            fi
            if [[ "$est_time" =~ ([0-9]+)m ]]; then
                minutes=$(( minutes + ${BASH_REMATCH[1]} ))
            fi

            # Extract complexity from the task block
            local complexity=""
            for (( j=start+1; j<end; j++ )); do
                if [[ "${pln_lines[$j]}" =~ ^-[[:space:]]+\*\*Complexity\*\*:[[:space:]]*(.*) ]]; then
                    complexity="${BASH_REMATCH[1]}"
                    break
                fi
            done

            local max_minutes=30
            case "$complexity" in
                S)  max_minutes=120 ;;
                M)  max_minutes=240 ;;
                L)  max_minutes=480 ;;
                XL) max_minutes=960 ;;
            esac

            if [[ $minutes -gt $max_minutes ]]; then
                _add_issue "subtask_size" "Task $task_id" \
                    "Estimated time ($est_time) exceeds ${max_minutes}m limit for complexity $complexity — consider splitting" "$heading_line"
            fi
        fi

        # Check 3a: TDD must be yes or no — never recommend
        if [[ "$tdd_req" == "recommend" ]]; then
            _add_issue "tdd_ambiguous" "Task $task_id" \
                "TDD Required is 'recommend' — must be 'yes' or 'no'. Resolve during planning, not execution." "$heading_line"
        fi

        # Check 3: Execution config fields populated
        # Skip for already-completed tasks (audit baseline / [x] Status: Complete)
        local is_complete=false
        if [[ "$heading" =~ ^####[[:space:]]+Task[[:space:]]+[0-9]+\.[0-9]+:[[:space:]]+\[x\] ]]; then
            is_complete=true
        else
            for (( j=start+1; j<end; j++ )); do
                if [[ "${pln_lines[$j]}" =~ ^-[[:space:]]+\*\*Status\*\*:[[:space:]]*Complete ]]; then
                    is_complete=true
                    break
                fi
            done
        fi

        if [[ "$is_complete" == false ]]; then
            local missing_fields=""
            if [[ -z "$tdd_req" || "$tdd_req" =~ ^\[.*\]$ ]]; then
                missing_fields+="TDD Required, "
            fi
            if [[ -z "$auto_rev" || "$auto_rev" =~ ^\[.*\]$ ]]; then
                missing_fields+="Auto Review, "
            fi
            if [[ -z "$rev_type" || "$rev_type" =~ ^\[.*\]$ ]]; then
                missing_fields+="Review Type, "
            fi
            if [[ -z "$fresh_ctx" || "$fresh_ctx" =~ ^\[.*\]$ ]]; then
                missing_fields+="Fresh Context, "
            fi
            if [[ -n "$missing_fields" ]]; then
                missing_fields="${missing_fields%, }"
                _add_issue "execution_config" "Task $task_id" \
                    "Missing or placeholder execution config fields: $missing_fields" "$heading_line"
            fi
        fi

        # Check 4: Dependencies must be DECLARED on every incomplete subtask.
        # An omitted field is indistinguishable from "unknown", which forces the
        # executor to serialize the whole plan (see compute_ready_items in
        # plan-progress.sh). Requiring an explicit `none` is what makes parallel
        # dispatch possible at all.
        local deps_trim="${deps#"${deps%%[![:space:]]*}"}"
        deps_trim="${deps_trim%"${deps_trim##*[![:space:]]}"}"

        if [[ "$is_complete" == false ]] && { [[ -z "$deps_trim" ]] || [[ "$deps_trim" =~ ^\[.*\]$ ]]; }; then
            _add_issue "dependency_missing" "Task $task_id" \
                "Missing Dependencies field — declare it explicitly as 'none' or a list of Task N.M / 'Phase N complete' refs. Omitting it forces the executor to run the plan serially." "$heading_line"
        fi

        # Check 4b/4c/4d: ordering, dangling refs, self-reference
        if [[ -n "$deps_trim" ]] && ! [[ "$deps_trim" =~ ^([Nn]one|N/A|n/a|-|\[.*\])$ ]]; then
            local dep_refs
            dep_refs=$(echo "$deps_trim" | grep -oE '[0-9]+\.[0-9]+' || echo "")
            local phase_refs
            phase_refs=$(echo "$deps_trim" | grep -oiE '[Pp]hase[[:space:]]+[0-9]+' | grep -oE '[0-9]+' || echo "")

            if [[ -z "$dep_refs" ]] && [[ -z "$phase_refs" ]]; then
                _add_issue "dependency_unparseable" "Task $task_id" \
                    "Dependencies '$deps_trim' contains no recognizable ref — use 'none', 'Task N.M' (comma-separated), or 'Phase N complete'" "$heading_line"
            fi

            local dep_ref
            for dep_ref in $dep_refs; do
                local dep_major dep_minor task_major task_minor
                dep_major=$(echo "$dep_ref" | cut -d. -f1)
                dep_minor=$(echo "$dep_ref" | cut -d. -f2)
                task_major=$(echo "$task_id" | cut -d. -f1)
                task_minor=$(echo "$task_id" | cut -d. -f2)

                if [[ "$dep_ref" == "$task_id" ]]; then
                    _add_issue "dependency_self" "Task $task_id" \
                        "Task depends on itself — remove the self-reference" "$heading_line"
                elif [[ $dep_major -gt $task_major ]] || \
                     { [[ $dep_major -eq $task_major ]] && [[ $dep_minor -ge $task_minor ]]; }; then
                    _add_issue "dependency_order" "Task $task_id" \
                        "Forward dependency reference to Task $dep_ref — must depend on earlier tasks only" "$heading_line"
                elif [[ -z "${known_task_ids[$dep_ref]:-}" ]]; then
                    _add_issue "dependency_dangling" "Task $task_id" \
                        "Depends on Task $dep_ref, which does not exist in this plan" "$heading_line"
                fi
            done

            local phase_ref
            for phase_ref in $phase_refs; do
                local task_major
                task_major=$(echo "$task_id" | cut -d. -f1)
                # A mention of the task's own phase is prose framing, not an edge
                # ("Phase 2 starts after Phase 1 complete") — skip it.
                [[ $phase_ref -eq $task_major ]] && continue
                if [[ -z "${known_phases[$phase_ref]:-}" ]]; then
                    _add_issue "dependency_dangling" "Task $task_id" \
                        "Depends on Phase $phase_ref, which has no subtasks in this plan" "$heading_line"
                elif [[ $phase_ref -gt $task_major ]]; then
                    _add_issue "dependency_order" "Task $task_id" \
                        "Depends on Phase $phase_ref but lives in Phase $task_major — cannot depend on a later phase" "$heading_line"
                fi
            done
        fi
    done

    # Build issues array from NDJSON (single jq call)
    local issues="[]"
    if [[ -n "$issues_ndjson" ]]; then
        issues=$(echo "$issues_ndjson" | jq -s '.')
    fi

    local issue_count
    issue_count=$(echo "$issues" | jq 'length')

    if [[ "$issue_count" -eq 0 ]]; then
        log "${GREEN}✓${NC} All checks passed"
        exit_with_json "review_passed" "Plan review passed — all checks OK" "" \
            '"plan_file": '"$(echo "$pln_file" | jq -Rs .)"', "checks_run": 10, "issues_found": 0'
    else
        log "${YELLOW}⚠${NC} Found $issue_count issue(s)"
        exit_with_json "review_failed" "Plan review found $issue_count issue(s)" \
            "Fix the issues in the PLN document, then re-run --review" \
            '"plan_file": '"$(echo "$pln_file" | jq -Rs .)"', "checks_run": 10, "issues_found": '"$issue_count"', "issues": '"$issues"
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --load) SECTION="load"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --breakdown) SECTION="breakdown"; shift ;;
            --estimate) SECTION="estimate"; shift ;;
            --generate) SECTION="generate"; shift ;;
            --review) SECTION="review"; shift ;;
            --skip-review) SKIP_REVIEW=true; shift ;;
            --full) SECTION="full"; shift ;;
            --source) SOURCE="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        load)
            section_load
            ;;
        analyze)
            section_load
            section_analyze
            ;;
        breakdown)
            section_load
            section_analyze
            section_breakdown
            ;;
        estimate)
            section_load
            section_analyze
            section_breakdown
            section_estimate
            ;;
        generate)
            section_load
            section_analyze
            section_breakdown
            section_estimate
            section_generate
            ;;
        review)
            # Review can take SOURCE as task doc (finds PLN) or direct PLN path
            REVIEW_FILE="$SOURCE"
            section_review
            ;;
        full)
            section_load

            # At this point, LLM needs to take over with Opus
            # Return collected requirements and signal handoff
            exit_with_json "requires_opus" "Implementation planning requires Opus model" \
                "Script has loaded requirements. LLM must continue with model: opus for analysis, breakdown, and planning" \
                '"requirements": '"$REQUIREMENTS_DATA"
            ;;
    esac
}

# Run main function
main "$@"

#!/usr/bin/env bash
# task-close-sync.sh - Extract summary data and create summary document
# Sourced by task-close.sh — shares globals, no standalone execution

[[ -n "${_TASK_CLOSE_SYNC_LOADED:-}" ]] && return 0; _TASK_CLOSE_SYNC_LOADED=1

section_extract_summary_data() {
    print_header "Extract Summary Data"

    # Use single efficient pass to extract first + last 3 summaries (not all 12)
    # This avoids the performance issue with processing too many summaries
    local summaries_data=$(awk '
        /^## Completion Summary/ {
            if (in_summary && summary_idx > 0) {
                # Store previous summary before starting new one
                if (summary_idx == 1 || summary_idx > (total_summaries - 3)) {
                    completed[summary_idx] = current_completed
                    accomplished[summary_idx] = current_accomplished
                    went_well[summary_idx] = current_went_well
                    challenges[summary_idx] = current_challenges
                    patterns[summary_idx] = current_patterns
                }
            }
            summary_idx++
            in_summary = 1
            current_section = ""
            current_completed = ""
            current_accomplished = ""
            current_went_well = ""
            current_challenges = ""
            current_patterns = ""
            next
        }
        /^\*\*Completed\*\*:/ && in_summary {
            sub(/^\*\*Completed\*\*: */, "")
            current_completed = $0
            next
        }
        /^### What Was Accomplished/ && in_summary {
            current_section = "accomplished"
            next
        }
        /^### What Went Well/ && in_summary {
            current_section = "went_well"
            next
        }
        /^### Challenges/ && in_summary {
            current_section = "challenges"
            next
        }
        /^### Reusable Patterns/ && in_summary {
            current_section = "patterns"
            next
        }
        /^###/ && in_summary {
            current_section = ""
            next
        }
        /^---$/ && in_summary {
            # End of summary section
            if (summary_idx == 1 || summary_idx > (total_summaries - 3)) {
                completed[summary_idx] = current_completed
                accomplished[summary_idx] = current_accomplished
                went_well[summary_idx] = current_went_well
                challenges[summary_idx] = current_challenges
                patterns[summary_idx] = current_patterns
            }
            in_summary = 0
            next
        }
        in_summary && current_section != "" && NF > 0 {
            line = $0
            # Skip blank lines and heading markers
            if (line !~ /^$/ && line !~ /^###/ && line !~ /^\*\*/) {
                if (current_section == "accomplished") {
                    current_accomplished = current_accomplished (current_accomplished ? " " : "") line
                } else if (current_section == "went_well") {
                    current_went_well = current_went_well (current_went_well ? " " : "") line
                } else if (current_section == "challenges") {
                    current_challenges = current_challenges (current_challenges ? " " : "") line
                } else if (current_section == "patterns") {
                    current_patterns = current_patterns (current_patterns ? " " : "") line
                }
            }
        }
        END {
            # Store last summary if needed
            if (in_summary && (summary_idx == 1 || summary_idx > (total_summaries - 3))) {
                completed[summary_idx] = current_completed
                accomplished[summary_idx] = current_accomplished
                went_well[summary_idx] = current_went_well
                challenges[summary_idx] = current_challenges
                patterns[summary_idx] = current_patterns
            }
            total_summaries = summary_idx
            # Count how many we want (first + last 3)
            count = 0
            for (idx = 1; idx <= total_summaries; idx++) {
                if (idx == 1 || idx > total_summaries - 3) {
                    if (count > 0) print "|||"
                    print "COMPLETED=" completed[idx]
                    print "ACCOMPLISHED=" accomplished[idx]
                    print "WENT_WELL=" went_well[idx]
                    print "CHALLENGES=" challenges[idx]
                    print "PATTERNS=" patterns[idx]
                    count++
                }
            }
        }
    ' "$TASK_DOC")

    # Convert to JSON efficiently
    local summaries_json="["
    local first=true
    while IFS= read -r line; do
        if [[ "$line" == "|||" ]]; then
            [[ "$first" == "false" ]] && summaries_json+=","
            summaries_json+=$(printf '{"completed":%s,"accomplished":%s,"went_well":%s,"challenges":%s,"patterns":%s}' \
                "$(echo "$COMPLETED" | jq -Rs .)" \
                "$(echo "$ACCOMPLISHED" | jq -Rs .)" \
                "$(echo "$WENT_WELL" | jq -Rs .)" \
                "$(echo "$CHALLENGES" | jq -Rs .)" \
                "$(echo "$PATTERNS" | jq -Rs .)")
            first=false
            COMPLETED="" ACCOMPLISHED="" WENT_WELL="" CHALLENGES="" PATTERNS=""
        elif [[ "$line" =~ ^COMPLETED= ]]; then
            COMPLETED="${line#COMPLETED=}"
        elif [[ "$line" =~ ^ACCOMPLISHED= ]]; then
            ACCOMPLISHED="${line#ACCOMPLISHED=}"
        elif [[ "$line" =~ ^WENT_WELL= ]]; then
            WENT_WELL="${line#WENT_WELL=}"
        elif [[ "$line" =~ ^CHALLENGES= ]]; then
            CHALLENGES="${line#CHALLENGES=}"
        elif [[ "$line" =~ ^PATTERNS= ]]; then
            PATTERNS="${line#PATTERNS=}"
        fi
    done <<< "$summaries_data"

    # Add last summary if exists
    if [[ -n "$COMPLETED" ]]; then
        [[ "$first" == "false" ]] && summaries_json+=","
        summaries_json+=$(printf '{"completed":%s,"accomplished":%s,"went_well":%s,"challenges":%s,"patterns":%s}' \
            "$(echo "$COMPLETED" | jq -Rs .)" \
            "$(echo "$ACCOMPLISHED" | jq -Rs .)" \
            "$(echo "$WENT_WELL" | jq -Rs .)" \
            "$(echo "$CHALLENGES" | jq -Rs .)" \
            "$(echo "$PATTERNS" | jq -Rs .)")
    fi
    summaries_json+="]"

    # Rest of extraction (git, docs) - keep as is but optimize
    local git_log=$(git log --oneline --grep="Refs #${TASK_ID}" -20 2>/dev/null || echo "")
    local commit_count=$(echo "$git_log" | wc -l)
    local git_stats=$(git diff --stat "$DEFAULT_BRANCH..$CURRENT_BRANCH" 2>/dev/null | tail -1 || echo "N/A")
    local files_changed=$(git diff --name-only "$DEFAULT_BRANCH..$CURRENT_BRANCH" 2>/dev/null | wc -l)

    # Optimize document listing - single find, multiple greps
    local all_docs=$(find_by_id "$TASK_ID" | grep -E "\.(md|txt)$" || true)
    local docs_json=$(printf '{"tsk":%s,"pln":%s,"vrf":%s,"aud":%s,"rsk":%s,"inc":%s}' \
        "$(echo "$all_docs" | grep "TSK-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "PLN-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "VRF-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "AUD-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "RSK-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$(echo "$all_docs" | grep "INC-" | sed 's#.*/##' | jq -Rs 'split("\n") | map(select(length > 0))')")

    log "${GREEN}✓${NC} Extracted data (first + last 3 summaries, $(echo "$summaries_json" | jq '. | length') total)"

    # Return comprehensive data
    local json=$(printf '{"status":"needs_llm","next_action":"parse_content","section":"extract-summary-data","message":"Raw data extracted - needs AI synthesis","task_id":"%s","task_title":%s,"completion_summaries":%s,"git_log":%s,"commit_count":%d,"git_stats":%s,"files_changed":%d,"related_documents":%s,"pr_url":"%s","pr_state":"%s","branch":"%s","next_steps":["LLM: Read all completion_summaries and git data","LLM: Synthesize comprehensive narrative","LLM: Call --create-summary with synthesized content"],"timestamp":"%s"}' \
        "$TASK_ID" \
        "$(echo "$TASK_TITLE" | jq -Rs .)" \
        "$summaries_json" \
        "$(echo "$git_log" | jq -Rs 'split("\n") | map(select(length > 0))')" \
        "$commit_count" \
        "$(echo "$git_stats" | jq -Rs .)" \
        "$files_changed" \
        "$docs_json" \
        "$PR_URL" \
        "$PR_STATE" \
        "$CURRENT_BRANCH" \
        "$(date -Iseconds)")

    log_json "$json"
    exit 0
}

section_create_summary() {
    print_header "Create Summary Document"

    # Use AI-provided content or extract from flags
    local summary_title="${AI_SUMMARY_TITLE:-$TASK_TITLE}"
    local summary_overview="${AI_SUMMARY_OVERVIEW}"
    local summary_accomplishments="${AI_SUMMARY_ACCOMPLISHMENTS}"
    local summary_key_outcomes="${AI_SUMMARY_KEY_OUTCOMES}"
    local summary_patterns="${AI_SUMMARY_PATTERNS}"
    local completion_timestamp="${AI_SUMMARY_TIMESTAMP:-$(date -Iseconds)}"
    local datetime=$(echo "$completion_timestamp" | sed 's/[:-]//g;s/T//;s/\+.*//;s/\(........\).*/\1/')

    # Extract task slug from TSK document filename
    local tsk_filename=$(basename "$TASK_DOC")
    TASK_SLUG=$(echo "$tsk_filename" | sed -E 's/^[0-9]{4}-[0-9]{10}-TSK-//' | sed 's/.md$//')

    SUMMARY_FILENAME="${TASK_ID}-${datetime}-SUM-${TASK_SLUG}.md"
    local summary_path="${DOCS_DIR}/completed/${RANGE_FOLDER}/${SUMMARY_FILENAME}"

    # Ensure completed range folder exists
    mkdir -p "${DOCS_DIR}/completed/${RANGE_FOLDER}"

    # Get related documents for listing
    local all_docs=$(find_by_id "$TASK_ID" | grep -E "\.(md|txt)$" || true)
    local tsk_list=$(echo "$all_docs" | grep "TSK-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local pln_list=$(echo "$all_docs" | grep "PLN-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local vrf_list=$(echo "$all_docs" | grep "VRF-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local aud_list=$(echo "$all_docs" | grep "AUD-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local rsk_list=$(echo "$all_docs" | grep "RSK-" | sed 's#.*/##' | sed 's/^/- /' || true)
    local inc_list=$(echo "$all_docs" | grep "INC-" | sed 's#.*/##' | sed 's/^/- /' || true)

    # Create summary document
    cat > "$summary_path" << EOF
# Summary: ${summary_title}

**Task ID**: $TASK_ID
**Type**: Summary (SUM)
**Status**: ✓ Completed
**Date**: $completion_timestamp

---

## Overview

${summary_overview}

---

## What Was Accomplished

${summary_accomplishments}

---

## Key Outcomes

${summary_key_outcomes}

---

## Reusable Patterns

${summary_patterns}

---

## Related Documents

**Task Documents**:
${tsk_list:-None}

**Planning & Analysis**:
${pln_list:-None}

**Verification & Testing**:
${vrf_list:-None}

**Audits & Reviews**:
${aud_list:-None}

**Risk Analysis**:
${rsk_list:-None}

$(if [[ -n "$inc_list" ]]; then echo "**Incidents**:"; echo "$inc_list"; fi)
$(if [[ -n "$PR_URL" ]]; then echo "**PR/MR**: $PR_URL"; fi)

---

**Completed**: $completion_timestamp
**Status**: ✓ Completed
EOF

    git add "$summary_path"
    log "${GREEN}✓${NC} Summary document created: $SUMMARY_FILENAME"

    # Return success
    local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "create-summary",
  "message": "Summary document created",
  "summary_filename": "$SUMMARY_FILENAME",
  "summary_path": "$summary_path",
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    exit 0
}

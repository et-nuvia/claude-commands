#!/usr/bin/env bash
# check-current-task.sh - Verify active task and branch consistency
# Returns JSON with task details if valid, or error info if mismatched

set -euo pipefail

# Source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/doc-utils.sh"

# Helper: JSON output
output_json() {
  echo "$1"
}

# Main discovery logic
check_task() {
  if [[ ! -f ".current-task" ]]; then
    output_json '{"active": false, "error": ".current-task file not found"}'
    return 0
  fi

  # Use check_current_task from doc-utils.sh but capture its output
  local check_results
  local match_status=0
  
  # Separate declaration from assignment to capture exit code correctly
  set +e
  check_results=$(check_current_task 2>/dev/null)
  match_status=$?
  set -e
  
  # check_current_task returns:
  # 0: branch matches
  # 1: file missing (handled above)
  # 2: task ID missing
  # 3: branch mismatch
  if [[ $match_status -ne 0 && $match_status -ne 3 ]]; then
     output_json '{"active": false, "error": "Task context is invalid or incomplete (code '$match_status')"}'
     return 0
  fi

  # If we got here, we have a task. check_current_task prints task_id=... etc.
  local seq=$(echo "$check_results" | grep "^task_id=" | cut -d'=' -f2)
  # Fallback to old format
  [[ -z "$seq" ]] && seq=$(echo "$check_results" | grep "^sequence=" | cut -d'=' -f2)
  local expected=$(echo "$check_results" | grep "^expected_branch=" | cut -d'=' -f2)
  local current=$(echo "$check_results" | grep "^current_branch=" | cut -d'=' -f2)
  local doc=$(echo "$check_results" | grep "^primary_doc=" | cut -d'=' -f2)
  local branch_match=$(echo "$check_results" | grep "^branch_match=" | cut -d'=' -f2)
  
  local title=$(grep -m1 "^#[[:space:]]" "$doc" 2>/dev/null | sed 's/^#[[:space:]]*//;s/:.*$//' || echo "")
  local all_docs=$(find_by_id "$seq" | grep "/active/")
  local docs_list="[]"
  if [[ -n "$all_docs" ]]; then
    docs_list=$(echo "$all_docs" | jq -R . | jq -s .)
  fi

  jq -n \
    --argjson active true \
    --arg seq "$seq" \
    --arg title "$title" \
    --arg expected "$expected" \
    --arg current "$current" \
    --argjson match "$branch_match" \
    --arg doc "$doc" \
    --argjson docs "$docs_list" \
    '{active: $active, task_id: $seq, title: $title, expected_branch: $expected, current_branch: $current, branch_match: $match, primary_doc: $doc, related_docs: $docs}'
}

check_task

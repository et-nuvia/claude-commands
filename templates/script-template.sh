#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# {SCRIPT_NAME}.sh - {One-line description}
#
# Usage:
#   {SCRIPT_NAME}.sh [options] <arguments>
#   {SCRIPT_NAME}.sh --verbose <arguments>
#   {SCRIPT_NAME}.sh --summary
#   {SCRIPT_NAME}.sh --help
#
# Options:
#   --verbose    Detailed output for debugging
#   --summary    Display formatted summary
#   --json       JSON output (default)
#   --help       Show this help
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- PROJECT.yaml Auto-Read -------------------------------------------------
# Extract all needed config upfront. Use defaults if PROJECT.yaml missing.

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_YAML="${PROJECT_ROOT}/PROJECT.yaml"

if [[ -f "$PROJECT_YAML" ]]; then
    # Extract needed config in one batch
    CONFIG_VAR=$(yq e '.path.to.value' "$PROJECT_YAML" 2>/dev/null || echo "default")
    # Add all needed config vars here
else
    # Sensible defaults when PROJECT.yaml is missing
    CONFIG_VAR="default"
fi

# --- Helpers -----------------------------------------------------------------

output_json() {
    local status="$1" next_action="$2" message="$3"
    shift 3
    local data="${1:-{}}"
    cat <<EOF
{
  "status": "${status}",
  "next_action": "${next_action}",
  "message": "${message}",
  "data": ${data}
}
EOF
}

show_help() {
    sed -n '3,/^# =====/{ /^# =====/d; s/^# //; s/^#//; p }' "$0"
}

# --- Flag Parsing ------------------------------------------------------------

VERBOSE=false
SUMMARY=false
OUTPUT_MODE="json"

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v) VERBOSE=true; shift ;;
        --summary)    SUMMARY=true; shift ;;
        --json)       OUTPUT_MODE="json"; shift ;;
        --help|-h)    show_help; exit 0 ;;
        --)           shift; break ;;
        -*)           echo "Unknown option: $1" >&2; exit 1 ;;
        *)            break ;;
    esac
done

# --- Input Validation --------------------------------------------------------

# ARG1="${1:?Missing required argument: arg1}"

# --- Main Logic --------------------------------------------------------------

# TODO: Implement main functionality
#
# Pattern:
# 1. Gather inputs (args + PROJECT.yaml config)
# 2. Execute operations (API calls, git commands, etc.)
# 3. Make decisions internally (don't push to command)
# 4. Return JSON with next_action

# --- Summary Mode ------------------------------------------------------------

if [[ "$SUMMARY" == "true" ]]; then
    # Display formatted human-readable summary
    echo "=== Summary ==="
    echo "TODO: Implement summary output"
    exit 0
fi

# --- JSON Response -----------------------------------------------------------

if [[ "$VERBOSE" == "true" ]]; then
    output_json "success" "display_summary" "Operation completed" \
        '{"verbose": true, "details": "Additional debug info here"}'
else
    output_json "success" "display_summary" "Operation completed" \
        '{}'
fi

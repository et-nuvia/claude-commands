#!/usr/bin/env bash
#
# make-json-wrapper.sh - Run a command and emit a JSON envelope
#
# Usage:
#   make-json-wrapper.sh --target <name> --component <name> [--category testing|quality|service] -- <command...>
#
# Captures command stdout+stderr and exit code, measures duration, and
# emits a standard JSON envelope. For testing category, delegates to
# parse-test-output.sh for structured field extraction.
#
# Categories:
#   testing  - Parse pass/fail/skip/coverage via parse-test-output.sh
#   quality  - Parse error/warning counts from lint/typecheck output
#   service  - Parse docker compose output for service states
#   (default) - Raw output in message field

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET=""
COMPONENT=""
CATEGORY=""

#------------------------------------------------------------------------------
# Argument Parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --component) COMPONENT="$2"; shift 2 ;;
        --category) CATEGORY="$2"; shift 2 ;;
        --) shift; break ;;
        -h|--help)
            echo "Usage: make-json-wrapper.sh --target <name> --component <name> [--category testing|quality|service] -- <command...>"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo '{"status":"error","message":"--target is required"}' >&2
    exit 1
fi

if [[ -z "$COMPONENT" ]]; then
    COMPONENT="unknown"
fi

if [[ $# -eq 0 ]]; then
    echo '{"status":"error","message":"No command provided after --"}' >&2
    exit 1
fi

#------------------------------------------------------------------------------
# Execute Command
#------------------------------------------------------------------------------

TIMESTAMP=$(date -Iseconds)
START_MS=$(($(date +%s%N) / 1000000))

CMD_OUTPUT=""
CMD_EXIT=0
CMD_OUTPUT=$("$@" 2>&1) || CMD_EXIT=$?

END_MS=$(($(date +%s%N) / 1000000))
DURATION_MS=$((END_MS - START_MS))

#------------------------------------------------------------------------------
# Parse Output by Category
#------------------------------------------------------------------------------

escape_json_string() {
    # Escape for JSON: backslashes, quotes, newlines, tabs, control chars
    local input="$1"
    printf '%s' "$input" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()), end='')" 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g' | tr '\n' ' ' | head -c 2000)"
}

build_envelope() {
    local status="success"
    local next_action="display_summary"
    local extra_fields="$1"

    if [[ $CMD_EXIT -ne 0 ]]; then
        status="error"
        next_action="fix_error"
    fi

    local message
    message=$(echo "$CMD_OUTPUT" | tail -1 | head -c 200)

    cat <<EOF
{"status":"${status}","target":"${TARGET}","component":"${COMPONENT}","message":$(escape_json_string "$message"),"next_action":"${next_action}","exit_code":${CMD_EXIT},"duration_ms":${DURATION_MS},"timestamp":"${TIMESTAMP}"${extra_fields}}
EOF
}

case "$CATEGORY" in
    testing)
        # Delegate to parse-test-output.sh
        local_parser="${SCRIPT_DIR}/parse-test-output.sh"
        if [[ -x "$local_parser" ]]; then
            PARSED=$(echo "$CMD_OUTPUT" | "$local_parser" 2>/dev/null || echo '{"passed":0,"failed":0,"skipped":0,"coverage_pct":0,"duration_ms":0}')
            # Extract fields from parsed JSON
            passed=$(echo "$PARSED" | grep -o '"passed":[0-9]*' | cut -d: -f2)
            failed=$(echo "$PARSED" | grep -o '"failed":[0-9]*' | cut -d: -f2)
            skipped=$(echo "$PARSED" | grep -o '"skipped":[0-9]*' | cut -d: -f2)
            coverage_pct=$(echo "$PARSED" | grep -o '"coverage_pct":[0-9.]*' | cut -d: -f2)

            # Adjust status based on test results
            extra=",\"passed\":${passed:-0},\"failed\":${failed:-0},\"skipped\":${skipped:-0},\"coverage_pct\":${coverage_pct:-0}"

            # Override next_action for test failures
            if [[ ${failed:-0} -gt 0 ]]; then
                CMD_EXIT=1  # Force error status
            fi

            build_envelope "$extra"
        else
            build_envelope ""
        fi
        ;;

    quality)
        # Parse error/warning counts from lint/typecheck output
        errors=0; warnings=0; files_checked=0
        errors=$(echo "$CMD_OUTPUT" | grep -ciE '(error|Error|ERROR)' || echo "0")
        warnings=$(echo "$CMD_OUTPUT" | grep -ciE '(warning|Warning|WARNING)' || echo "0")
        # Attempt to count files from common patterns
        files_checked=$(echo "$CMD_OUTPUT" | grep -cE '^\S+\.(py|ts|tsx|js|jsx):' || echo "0")

        if [[ $CMD_EXIT -ne 0 ]]; then
            errors=$((errors > 0 ? errors : 1))
        fi

        build_envelope ",\"errors\":${errors},\"warnings\":${warnings},\"files_checked\":${files_checked}"
        ;;

    service)
        # Parse docker compose output for service states
        service_count=0
        service_count=$(echo "$CMD_OUTPUT" | grep -cE '(Started|Running|Created|Stopped|Removed)' || echo "0")
        build_envelope ",\"services_affected\":${service_count}"
        ;;

    *)
        # Default: raw output in message field
        build_envelope ""
        ;;
esac

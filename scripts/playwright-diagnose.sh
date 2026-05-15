#!/usr/bin/env bash
# playwright-diagnose.sh - Playwright JSON report parser
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/playwright-diagnose.sh [--json|--raw] --service <svc> [--file <spec>] [--grep <pat>] [--trace]
#
# Called by test-diagnose.sh when framework is playwright.
# Runs playwright with JSON reporter, parses failures, categorizes errors.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
OUTPUT_MODE="json"
SERVICE=""
FILE_FILTER=""
GREP_FILTER=""
TRACE_MODE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

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
  "framework": "playwright",
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

    echo "$json_base"
}

#------------------------------------------------------------------------------
# Categorize Playwright errors
#------------------------------------------------------------------------------

categorize_error() {
    local error_msg="$1"

    if echo "$error_msg" | grep -qi "locator\|selector\|getBy\|not found\|no element"; then
        echo "selector_not_found"
    elif echo "$error_msg" | grep -qi "timeout\|exceeded\|waiting for"; then
        echo "timeout"
    elif echo "$error_msg" | grep -qi "race\|flaky\|intermittent\|strict mode"; then
        echo "race_condition"
    elif echo "$error_msg" | grep -qi "net::\|ERR_\|ECONNREFUSED\|fetch\|network"; then
        echo "network_error"
    elif echo "$error_msg" | grep -qi "expect\|toBe\|toHave\|toContain\|assert"; then
        echo "assertion"
    else
        echo "unknown"
    fi
}

#------------------------------------------------------------------------------
# Run Playwright and Parse Results
#------------------------------------------------------------------------------

run_and_parse() {
    local cmd="npx playwright test --reporter=json"

    if [[ -n "$FILE_FILTER" ]]; then
        cmd="$cmd $FILE_FILTER"
    fi

    if [[ -n "$GREP_FILTER" ]]; then
        cmd="$cmd --grep \"$GREP_FILTER\""
    fi

    log "${BLUE}Running: $cmd${NC}"

    # Run via docker-exec, capture output
    local raw_output
    local exit_code=0
    raw_output=$("${SCRIPT_DIR}/docker-exec.sh" -s "$SERVICE" -- sh -c "$cmd 2>&1") || exit_code=$?

    # Try to parse as JSON
    if ! echo "$raw_output" | python3 -m json.tool > /dev/null 2>&1; then
        # Not valid JSON — return raw output as error
        local escaped_output
        escaped_output=$(echo "$raw_output" | head -20 | sed 's/"/\\"/g' | tr '\n' ' ')
        output_json "error" "fix_error" "Playwright did not produce valid JSON output" \
            "\"raw_output\": \"${escaped_output}\""
        return
    fi

    # Parse JSON report
    local total passed failed
    total=$(echo "$raw_output" | python3 -c "import sys,json; r=json.load(sys.stdin); print(len(r.get('suites',[])))") || total=0
    passed=$(echo "$raw_output" | python3 -c "
import sys,json
r=json.load(sys.stdin)
count=0
def walk(suites):
    global count
    for s in suites:
        for spec in s.get('specs',[]):
            for t in spec.get('tests',[]):
                for result in t.get('results',[]):
                    if result.get('status')=='passed': count+=1
        walk(s.get('suites',[]))
walk(r.get('suites',[]))
print(count)
" 2>/dev/null) || passed=0

    # Extract failures
    local failures_json
    failures_json=$(echo "$raw_output" | python3 -c "
import sys,json
r=json.load(sys.stdin)
failures=[]
def walk(suites, path=''):
    for s in suites:
        sp = (path + ' > ' + s.get('title','')) if path else s.get('title','')
        for spec in s.get('specs',[]):
            for t in spec.get('tests',[]):
                for result in t.get('results',[]):
                    if result.get('status') in ('failed','timedOut'):
                        err = ''
                        if result.get('errors'):
                            err = result['errors'][0].get('message','')[:300]
                        failures.append({
                            'test': sp + ' > ' + spec.get('title',''),
                            'file': spec.get('file',''),
                            'error': err,
                            'status': result.get('status',''),
                            'duration_ms': result.get('duration',0)
                        })
        walk(s.get('suites',[]), sp)
walk(r.get('suites',[]))
import json as j
print(j.dumps(failures))
" 2>/dev/null) || failures_json="[]"

    failed=$(echo "$failures_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null) || failed=0

    # Categorize each failure
    local categorized_json
    categorized_json=$(echo "$failures_json" | python3 -c "
import sys,json,subprocess
failures=json.load(sys.stdin)
for f in failures:
    err = f.get('error','').lower()
    if any(k in err for k in ['locator','selector','getby','not found','no element']):
        f['category'] = 'selector_not_found'
    elif any(k in err for k in ['timeout','exceeded','waiting for']):
        f['category'] = 'timeout'
    elif any(k in err for k in ['race','flaky','strict mode']):
        f['category'] = 'race_condition'
    elif any(k in err for k in ['net::','err_','econnrefused','network']):
        f['category'] = 'network_error'
    elif any(k in err for k in ['expect','tobe','tohave','tocontain','assert']):
        f['category'] = 'assertion'
    else:
        f['category'] = 'unknown'
print(json.dumps(failures))
" 2>/dev/null) || categorized_json="$failures_json"

    if [[ "$failed" -eq 0 ]]; then
        output_json "success" "display_summary" "All $passed tests passed" \
            "\"passed\": $passed, \"failed\": 0, \"failures\": []"
    else
        output_json "failure" "fix_failures" "$failed of $((passed + failed)) tests failed" \
            "\"passed\": $passed, \"failed\": $failed, \"failures\": $categorized_json"
    fi
}

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --service|-s) SERVICE="$2"; shift 2 ;;
        --file) FILE_FILTER="$2"; shift 2 ;;
        --grep) GREP_FILTER="$2"; shift 2 ;;
        --trace) TRACE_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] --service <svc> [--file <spec>] [--grep <pat>] [--trace]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SERVICE" ]]; then
    echo "Error: --service is required" >&2
    exit 1
fi

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

run_and_parse

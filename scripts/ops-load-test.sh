#!/usr/bin/env bash
# ops-load-test.sh - Plan and execute load testing
#
# Usage:
#   ops-load-test.sh --json --full              # Complete flow
#   ops-load-test.sh --json --select-tool       # Select tool only
#   ops-load-test.sh --json --generate-script   # Generate test script
#   ops-load-test.sh --json --run-test          # Run test
#   ops-load-test.sh --json --generate-report   # Generate report
#   ops-load-test.sh --raw --<section>          # Verbose debugging
#
# JSON Response Format:
# {
#   "status": "success|intervention_needed|error",
#   "section": "select-tool|generate-script|run-test|generate-report",
#   "message": "Human-readable summary",
#   "timestamp": "ISO 8601 datetime",
#   "tool": "k6|locust|jmeter|ab",
#   "target_url": "URL",
#   "vus": number,
#   "duration": "5m",
#   "ramp_up": "30s",
#   "test_script": "path/to/script",
#   "test_results": "path/to/results",
#   "report_file": "path/to/report"
# }

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        intervention_needed) echo "confirm_action" ;;
        *) _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

OUTPUT_MODE="json"  # json or raw
SECTION=""

TOOL=""
TARGET_URL=""
VUS=""
DURATION=""
RAMP_UP=""
TEST_SCRIPT=""
TEST_RESULTS=""
REPORT_FILE=""

# ============================================================================
# Helper Functions
# ============================================================================

json_response() {
    local status="$1"
    local section="$2"
    local message="$3"

    log_json "$(cat <<EOF
{
  "status": "$status",
  "next_action": "$(map_status_to_action "$status")",
  "section": "$section",
  "message": "$message",
  "timestamp": "$(date -Iseconds)",
  "tool": "$TOOL",
  "target_url": "$TARGET_URL",
  "vus": ${VUS:-0},
  "duration": "$DURATION",
  "ramp_up": "$RAMP_UP",
  "test_script": "$TEST_SCRIPT",
  "test_results": "$TEST_RESULTS",
  "report_file": "$REPORT_FILE"
}
EOF
)"
}

error_response() {
    local section="$1"
    local message="$2"
    local details="${3:-}"

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        SECTION="$section"
        exit_with_json "error" "$message" "$details"
    else
        echo "Error in section: $section"
        echo "$message"
        [[ -n "$details" ]] && echo "Details: $details"
    fi
    exit 1
}

intervention_response() {
    local section="$1"
    local message="$2"
    shift 2
    local next_steps=("$@")

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local steps_json=""
        for step in "${next_steps[@]}"; do
            [[ -n "$steps_json" ]] && steps_json+=","
            steps_json+="\"$step\""
        done

        log_json "$(cat <<EOF
{
  "status": "intervention_needed",
  "next_action": "$(map_status_to_action "intervention_needed")",
  "section": "$section",
  "message": "$message",
  "next_steps": [$steps_json],
  "timestamp": "$(date -Iseconds)",
  "tool": "$TOOL",
  "target_url": "$TARGET_URL",
  "vus": ${VUS:-0},
  "duration": "$DURATION",
  "ramp_up": "$RAMP_UP"
}
EOF
)"
    else
        echo "Intervention needed in section: $section"
        echo "$message"
        echo "Next steps:"
        for step in "${next_steps[@]}"; do
            echo "  - $step"
        done
    fi
}

# ============================================================================
# Section: Select Tool
# ============================================================================

section_select_tool() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Load Testing Tool Selection"
        echo "══════════════════════════════════════"
        echo ""
        echo "Available tools:"
        echo "1. k6 (JavaScript-based, recommended)"
        echo "2. Locust (Python-based)"
        echo "3. JMeter (GUI-based)"
        echo "4. ab (Apache Bench, simple)"
    fi

    # Intervention needed - user must select tool
    intervention_response "select-tool" "User must select load testing tool" \
        "Choose tool: k6, locust, jmeter, or ab" \
        "Provide target URL, VUs, duration, and ramp-up time" \
        "After selection, run: ~/.claude/scripts/ops-load-test.sh --json --generate-script"
}

# ============================================================================
# Section: Define Test Scenario
# ============================================================================

section_define_scenario() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Test scenario definition"
        echo "══════════════════════════════════════"
        echo ""
    fi

    # Intervention needed - user must provide test parameters
    intervention_response "define-scenario" "User must define test scenario" \
        "Provide target URL" \
        "Specify number of virtual users (VUs)" \
        "Specify test duration (e.g., 5m, 30s)" \
        "Specify ramp-up time (e.g., 30s)" \
        "After definition, run: ~/.claude/scripts/ops-load-test.sh --json --generate-script"
}

# ============================================================================
# Section: Generate Test Script
# ============================================================================

section_generate_script() {
    # Validate required parameters
    if [[ -z "$TOOL" ]]; then
        error_response "generate-script" "Tool not specified" "Pass --tool flag (e.g. --tool k6)"
    fi

    if [[ -z "$TARGET_URL" ]]; then
        error_response "generate-script" "Target URL not specified" "Pass --target-url flag"
    fi

    if [[ -z "$VUS" ]]; then
        error_response "generate-script" "VUs not specified" "Set VUS environment variable"
    fi

    if [[ -z "$DURATION" ]]; then
        error_response "generate-script" "Duration not specified" "Set DURATION environment variable"
    fi

    if [[ -z "$RAMP_UP" ]]; then
        error_response "generate-script" "Ramp-up time not specified" "Set RAMP_UP environment variable"
    fi

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Generating test script for $TOOL..."
        echo ""
    fi

    case "$TOOL" in
        k6)
            TEST_SCRIPT="load-test.js"
            cat > "$TEST_SCRIPT" << EOF
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');

export let options = {
  stages: [
    { duration: '$RAMP_UP', target: $VUS }, // Ramp up
    { duration: '$DURATION', target: $VUS }, // Stay at peak
    { duration: '$RAMP_UP', target: 0 }, // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'], // 95% of requests under 500ms
    errors: ['rate<0.05'], // Error rate under 5%
  },
};

export default function () {
  const res = http.get('$TARGET_URL');

  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  }) || errorRate.add(1);

  sleep(1); // 1 request per second per VU
}
EOF
            ;;

        locust)
            TEST_SCRIPT="locustfile.py"
            cat > "$TEST_SCRIPT" << EOF
from locust import HttpUser, task, between

class LoadTestUser(HttpUser):
    wait_time = between(1, 3)

    @task
    def load_test(self):
        self.client.get('$TARGET_URL')
EOF
            ;;

        jmeter)
            error_response "generate-script" "JMeter script generation not implemented" \
                "JMeter requires GUI for test plan creation. Use k6 or Locust for scriptable tests."
            ;;

        ab)
            # Apache Bench doesn't need a script file
            TEST_SCRIPT="(command-line only)"
            ;;

        *)
            error_response "generate-script" "Unknown tool: $TOOL" \
                "Supported tools: k6, locust, jmeter, ab"
            ;;
    esac

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        [[ -f "$TEST_SCRIPT" ]] && echo "✓ Created: $TEST_SCRIPT"
    fi

    json_response "success" "generate-script" "Test script generated successfully"
}

# ============================================================================
# Section: Run Test
# ============================================================================

section_run_test() {
    if [[ -z "$TOOL" ]]; then
        error_response "run-test" "Tool not specified" "Set TOOL environment variable"
    fi

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Running load test with $TOOL..."
        echo ""
    fi

    case "$TOOL" in
        k6)
            if [[ ! -f "$TEST_SCRIPT" ]]; then
                error_response "run-test" "Test script not found: $TEST_SCRIPT" \
                    "Run: ~/.claude/scripts/ops-load-test.sh --json --generate-script"
            fi

            if ! command -v k6 &> /dev/null; then
                error_response "run-test" "k6 not installed" \
                    "Install with: brew install k6 (macOS) or apt install k6 (Linux)"
            fi

            TEST_RESULTS="load-test-results.json"
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                k6 run "$TEST_SCRIPT" --out "json=$TEST_RESULTS"
            else
                k6 run "$TEST_SCRIPT" --out "json=$TEST_RESULTS" &> /dev/null || \
                    error_response "run-test" "k6 test failed" "Run with --raw for detailed output"
            fi
            ;;

        locust)
            if [[ ! -f "$TEST_SCRIPT" ]]; then
                error_response "run-test" "Test script not found: $TEST_SCRIPT" \
                    "Run: ~/.claude/scripts/ops-load-test.sh --json --generate-script"
            fi

            if ! command -v locust &> /dev/null; then
                error_response "run-test" "Locust not installed" \
                    "Install with: pip install locust"
            fi

            TEST_RESULTS="locust-results.csv"
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                locust --headless --users "$VUS" --spawn-rate 10 --run-time "$DURATION" \
                    --host "$TARGET_URL" --csv="$(basename "$TEST_RESULTS" .csv)"
            else
                locust --headless --users "$VUS" --spawn-rate 10 --run-time "$DURATION" \
                    --host "$TARGET_URL" --csv="$(basename "$TEST_RESULTS" .csv)" &> /dev/null || \
                    error_response "run-test" "Locust test failed" "Run with --raw for detailed output"
            fi
            ;;

        ab)
            if ! command -v ab &> /dev/null; then
                error_response "run-test" "Apache Bench not installed" \
                    "Install with: apt install apache2-utils (Linux) or brew install httpd (macOS)"
            fi

            TEST_RESULTS="ab-results.txt"
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                ab -n 10000 -c "$VUS" "$TARGET_URL" | tee "$TEST_RESULTS"
            else
                ab -n 10000 -c "$VUS" "$TARGET_URL" > "$TEST_RESULTS" 2>&1 || \
                    error_response "run-test" "Apache Bench test failed" "Run with --raw for detailed output"
            fi
            ;;

        *)
            error_response "run-test" "Unknown tool: $TOOL" \
                "Supported tools: k6, locust, ab"
            ;;
    esac

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo ""
        echo "✓ Load test complete"
    fi

    json_response "success" "run-test" "Load test completed successfully"
}

# ============================================================================
# Section: Generate Report
# ============================================================================

section_generate_report() {
    if [[ -z "$TOOL" ]]; then
        error_response "generate-report" "Tool not specified" "Set TOOL environment variable"
    fi

    REPORT_FILE="docs/load-tests/$(date +%Y-%m-%d)-load-test-report.md"
    mkdir -p docs/load-tests

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Generating load test report..."
        echo ""
    fi

    cat > "$REPORT_FILE" << EOF
# Load Test Report

**Date**: $(date -Iseconds)
**Tool**: $TOOL
**Target**: $TARGET_URL
**VUs**: $VUS
**Duration**: $DURATION

---

## Test Configuration

- **Ramp-up**: $RAMP_UP
- **Test Script**: $TEST_SCRIPT
- **Results File**: $TEST_RESULTS

---

## Test Results

$(if [[ -f "$TEST_RESULTS" ]]; then
  echo "Results available at: $TEST_RESULTS"
  echo ""
  echo "### Summary"
  echo ""
  case "$TOOL" in
    k6)
      echo "See JSON results in $TEST_RESULTS"
      ;;
    locust)
      echo "See CSV results in $TEST_RESULTS"
      ;;
    ab)
      echo "\`\`\`"
      grep -E "(Requests per second|Time per request|Transfer rate)" "$TEST_RESULTS" || echo "No summary available"
      echo "\`\`\`"
      ;;
  esac
else
  echo "Test not run yet - execute run-test section first"
fi)

---

## Recommendations

- Review performance metrics
- Identify bottlenecks
- Optimize slow endpoints
- Scale infrastructure if needed

EOF

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "✓ Load test report: $REPORT_FILE"
    fi

    json_response "success" "generate-report" "Load test report generated successfully"
}

# ============================================================================
# Main Execution
# ============================================================================

usage() {
    cat << EOF
Usage: $0 [--json|--raw] [--full|--<section>]

Sections:
  --full              Run complete flow (interactive)
  --select-tool       Select load testing tool
  --define-scenario   Define test scenario parameters
  --generate-script   Generate test script
  --run-test          Run load test
  --generate-report   Generate test report

Output Modes:
  --json              JSON output (default)
  --raw               Verbose debugging output

Environment Variables (for non-interactive use):
  TOOL                Load testing tool (k6, locust, jmeter, ab)
  TARGET_URL          Target URL for load testing
  VUS                 Number of virtual users
  DURATION            Test duration (e.g., 5m, 30s)
  RAMP_UP             Ramp-up time (e.g., 30s)

Examples:
  # Interactive flow
  $0 --json --full

  # Generate script with parameters
  TOOL=k6 TARGET_URL=https://example.com VUS=50 DURATION=5m RAMP_UP=30s \\
    $0 --json --generate-script

  # Run test
  TOOL=k6 $0 --json --run-test

  # Debug with verbose output
  $0 --raw --run-test
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --select-tool) SECTION="select-tool"; shift ;;
        --define-scenario) SECTION="define-scenario"; shift ;;
        --generate-script) SECTION="generate-script"; shift ;;
        --run-test) SECTION="run-test"; shift ;;
        --generate-report) SECTION="generate-report"; shift ;;
        --tool) TOOL="$2"; shift 2 ;;
        --target-url) TARGET_URL="$2"; shift 2 ;;
        --vus) VUS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --ramp-up) RAMP_UP="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Default to full if no section specified
[[ -z "$SECTION" ]] && SECTION="full"

# Execute requested section(s)
case "$SECTION" in
    full)
        # Full flow requires user intervention at multiple points
        section_select_tool
        ;;

    select-tool)
        section_select_tool
        ;;

    define-scenario)
        section_define_scenario
        ;;

    generate-script)
        section_generate_script
        ;;

    run-test)
        section_run_test
        ;;

    generate-report)
        section_generate_report
        ;;

    *)
        error_response "main" "Unknown section: $SECTION" "See --help for usage"
        ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/pipeline-debug.sh [--json|--raw] [--full|--section] [pipeline_id]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --detect:    Detect CI/CD platform and get pipeline ID
#   --jobs:      Get failed job details
#   --logs:      Extract and analyze job logs
#   --analyze:   Identify failure patterns
#   --report:    Generate debug report
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: pipeline-debug.sh --json --full [pipeline_id]
#   2. If error: Returns JSON with error details
#   3. LLM can retry with --raw for more debugging info
#   4. Or LLM runs specific --section after analyzing output

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, detect, jobs, logs, analyze, report
PLATFORM=""         # github or gitlab
PIPELINE_ID=""
PROJECT_ID=""
FAILED_JOBS_DATA=""
LOGS_DIR="/tmp/pipeline-logs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Detect Platform and Get Pipeline ID
section_detect() {
    log "${BLUE}Detecting CI/CD Platform${NC}"

    # Try to detect platform
    if gh auth status &>/dev/null; then
        PLATFORM="github"
        log "${GREEN}✓${NC} Detected GitHub Actions"
    elif glab auth status &>/dev/null; then
        PLATFORM="gitlab"
        log "${GREEN}✓${NC} Detected GitLab CI"
    else
        exit_with_json "error" "Cannot detect CI/CD platform" \
            "Neither 'gh' nor 'glab' CLI is authenticated. Run 'gh auth login' or 'glab auth status' first."
    fi

    # If pipeline ID not provided, get latest failed run
    if [[ -z "$PIPELINE_ID" ]]; then
        log "Fetching latest failed pipeline..."

        if [[ "$PLATFORM" == "github" ]]; then
            local failed_runs=$(gh run list --limit 20 --json status,conclusion,number,createdAt,displayTitle \
                --jq '.[] | select(.conclusion == "failure")')

            if [[ -z "$failed_runs" ]]; then
                exit_with_json "success" "No recent failures found" "All recent pipelines passed"
            fi

            PIPELINE_ID=$(echo "$failed_runs" | head -1 | jq -r '.number')
            log "${GREEN}✓${NC} Found failed run: #${PIPELINE_ID}"
        else
            # GitLab
            PROJECT_ID=$(glab api projects/:id --jq '.id')
            local failed_pipelines=$(glab api "projects/$PROJECT_ID/pipelines?status=failed&per_page=20")

            if [[ $(echo "$failed_pipelines" | jq 'length') -eq 0 ]]; then
                exit_with_json "success" "No recent failures found" "All recent pipelines passed"
            fi

            PIPELINE_ID=$(echo "$failed_pipelines" | jq -r '.[0].id')
            log "${GREEN}✓${NC} Found failed pipeline: #${PIPELINE_ID}"
        fi
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "detect" ]]; then
        local extra_json=$(cat <<EOF
"platform": "$PLATFORM",
  "pipeline_id": "$PIPELINE_ID"
EOF
)
        exit_with_json "success" "Platform detected and pipeline identified" "" "$extra_json"
    fi

    log "${GREEN}✓${NC} Detection complete: $PLATFORM pipeline #${PIPELINE_ID}"
}

# Section 2: Get Failed Jobs
section_jobs() {
    log "${BLUE}Fetching Failed Job Details${NC}"

    local failed_jobs_json
    if [[ "$PLATFORM" == "github" ]]; then
        local run_details=$(gh run view "$PIPELINE_ID" --json jobs)
        failed_jobs_json=$(echo "$run_details" | jq -c '[.jobs[] | select(.conclusion == "failure") | {name: .name, id: .databaseId, status: .conclusion}]')

        if [[ $(echo "$failed_jobs_json" | jq 'length') -eq 0 ]]; then
            exit_with_json "error" "No failed jobs found in run #${PIPELINE_ID}" \
                "The pipeline may have been rerun successfully, or the jobs are still running."
        fi
    else
        # GitLab
        local pipeline_jobs=$(glab api "projects/$PROJECT_ID/pipelines/$PIPELINE_ID/jobs")
        failed_jobs_json=$(echo "$pipeline_jobs" | jq -c '[.[] | select(.status == "failed") | {name: .name, id: .id, status: .status}]')

        if [[ $(echo "$failed_jobs_json" | jq 'length') -eq 0 ]]; then
            exit_with_json "error" "No failed jobs found in pipeline #${PIPELINE_ID}" \
                "The pipeline may have been rerun successfully, or the jobs are still running."
        fi
    fi

    FAILED_JOBS_DATA="$failed_jobs_json"
    log "${GREEN}✓${NC} Found $(echo "$failed_jobs_json" | jq 'length') failed job(s)"

    # If running only this section, return now
    if [[ "$SECTION" == "jobs" ]]; then
        local extra_json=$(cat <<EOF
"platform": "$PLATFORM",
  "pipeline_id": "$PIPELINE_ID",
  "failed_jobs": $failed_jobs_json
EOF
)
        exit_with_json "success" "Failed jobs retrieved" "" "$extra_json"
    fi
}

# Section 3: Extract Job Logs
section_logs() {
    log "${BLUE}Extracting Job Logs${NC}"

    mkdir -p "$LOGS_DIR"

    local job_count=$(echo "$FAILED_JOBS_DATA" | jq 'length')
    log "Downloading logs for $job_count job(s)..."

    local i=0
    while [[ $i -lt $job_count ]]; do
        local job_name=$(echo "$FAILED_JOBS_DATA" | jq -r ".[$i].name")
        local job_id=$(echo "$FAILED_JOBS_DATA" | jq -r ".[$i].id")

        log "  Fetching: $job_name (ID: $job_id)"

        if [[ "$PLATFORM" == "github" ]]; then
            gh run view --job="$job_id" --log > "${LOGS_DIR}/${job_name}.log" 2>/dev/null || {
                log "${YELLOW}⚠${NC} Failed to fetch logs for $job_name"
            }
        else
            glab api "projects/$PROJECT_ID/jobs/$job_id/trace" > "${LOGS_DIR}/${job_name}.log" 2>/dev/null || {
                log "${YELLOW}⚠${NC} Failed to fetch logs for $job_name"
            }
        fi

        ((i++))
    done

    log "${GREEN}✓${NC} Logs saved to $LOGS_DIR"

    # If running only this section, return now
    if [[ "$SECTION" == "logs" ]]; then
        local extra_json=$(cat <<EOF
"platform": "$PLATFORM",
  "pipeline_id": "$PIPELINE_ID",
  "failed_jobs": $FAILED_JOBS_DATA,
  "logs_directory": "$LOGS_DIR"
EOF
)
        exit_with_json "success" "Logs extracted" "" "$extra_json"
    fi
}

# Section 4: Analyze Failure Patterns
section_analyze() {
    log "${BLUE}Analyzing Failure Patterns${NC}"

    local failure_type="unknown"
    local recommendations=()

    # Check for dependency issues
    if grep -qiE "could not find|module not found|package not found|cannot import" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="dependency"
        recommendations+=("Check requirements.txt/package.json for correct dependencies")
        recommendations+=("Verify dependency versions are compatible")
        recommendations+=("Check if private packages need authentication")
        log "${YELLOW}⚠${NC} Dependency installation failure detected"
    fi

    # Check for test failures
    if grep -qiE "test.*failed|assertion error|1 failed" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="test"
        recommendations+=("Run tests locally to reproduce: make test")
        recommendations+=("Check test logs for specific assertion failures")
        recommendations+=("Verify test data/fixtures are correct")
        log "${YELLOW}⚠${NC} Test failure detected"
    fi

    # Check for linting issues
    if grep -qiE "lint|style|format" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="lint"
        recommendations+=("Run linter locally: make lint")
        recommendations+=("Auto-fix issues: make format")
        recommendations+=("Check .ruff.toml or similar config")
        log "${YELLOW}⚠${NC} Linting/formatting failure detected"
    fi

    # Check for build failures
    if grep -qiE "build failed|compilation error|docker build" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="build"
        recommendations+=("Test build locally: docker build .")
        recommendations+=("Check Dockerfile syntax")
        recommendations+=("Verify all COPY/ADD paths exist")
        log "${YELLOW}⚠${NC} Build failure detected"
    fi

    # Check for timeout
    if grep -qiE "timeout|timed out|exceeded.*time" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="timeout"
        recommendations+=("Increase job timeout in pipeline config")
        recommendations+=("Optimize slow operations")
        recommendations+=("Check for hanging processes")
        log "${YELLOW}⚠${NC} Timeout detected"
    fi

    # Check for resource issues
    if grep -qiE "out of memory|disk.*full|no space" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="resource"
        recommendations+=("Increase runner/executor resources")
        recommendations+=("Clean up temporary files during build")
        recommendations+=("Use smaller base images")
        log "${YELLOW}⚠${NC} Resource exhaustion detected"
    fi

    # Check for authentication issues
    if grep -qiE "permission denied|unauthorized|authentication failed|403|401" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="auth"
        recommendations+=("Verify secrets are configured correctly")
        recommendations+=("Check token/key expiration")
        recommendations+=("Verify repository permissions")
        log "${YELLOW}⚠${NC} Authentication failure detected"
    fi

    # Check for flaky tests
    if grep -qiE "flaky|intermittent|sometimes fails" "$LOGS_DIR"/*.log 2>/dev/null; then
        failure_type="flaky"
        recommendations+=("Identify and fix non-deterministic behavior")
        recommendations+=("Add proper waits for async operations")
        recommendations+=("Remove sleeps, use proper synchronization")
        log "${YELLOW}⚠${NC} Flaky test detected"
    fi

    # Extract error excerpts
    local error_excerpts=""
    for log_file in "$LOGS_DIR"/*.log; do
        if [[ -f "$log_file" ]]; then
            local job_name=$(basename "$log_file" .log)
            local errors=$(grep -iE "error|failed|fatal" "$log_file" 2>/dev/null | tail -10 || echo "No errors found")
            error_excerpts="${error_excerpts}=== ${job_name} ===\n${errors}\n\n"
        fi
    done

    log "${GREEN}✓${NC} Analysis complete: $failure_type"

    # If running only this section, return now
    if [[ "$SECTION" == "analyze" ]]; then
        local recommendations_json=$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .)
        local extra_json=$(cat <<EOF
"platform": "$PLATFORM",
  "pipeline_id": "$PIPELINE_ID",
  "failed_jobs": $FAILED_JOBS_DATA,
  "failure_type": "$failure_type",
  "recommendations": $recommendations_json,
  "error_excerpts": $(echo -e "$error_excerpts" | jq -Rs .)
EOF
)
        exit_with_json "success" "Failure patterns analyzed" "" "$extra_json"
    fi
}

# Section 5: Generate Debug Report
section_report() {
    log "${BLUE}Generating Debug Report${NC}"

    local report_dir="docs/pipeline-debug"
    local report_file="${report_dir}/$(date +%Y-%m-%d)-debug-report.md"
    mkdir -p "$report_dir"

    # Re-analyze for report data (in case running only --report)
    local failure_type="unknown"
    local recommendations=()

    if [[ -d "$LOGS_DIR" ]] && [[ -n "$(ls -A "$LOGS_DIR" 2>/dev/null)" ]]; then
        # Analyze logs
        if grep -qiE "could not find|module not found|package not found|cannot import" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="dependency"
            recommendations+=("Check requirements.txt/package.json for correct dependencies")
        fi
        if grep -qiE "test.*failed|assertion error|1 failed" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="test"
            recommendations+=("Run tests locally: make test")
        fi
        if grep -qiE "lint|style|format" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="lint"
            recommendations+=("Run linter locally: make lint")
        fi
        if grep -qiE "build failed|compilation error|docker build" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="build"
            recommendations+=("Test build locally: docker build .")
        fi
        if grep -qiE "timeout|timed out|exceeded.*time" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="timeout"
            recommendations+=("Increase job timeout in pipeline config")
        fi
        if grep -qiE "out of memory|disk.*full|no space" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="resource"
            recommendations+=("Increase runner/executor resources")
        fi
        if grep -qiE "permission denied|unauthorized|authentication failed|403|401" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="auth"
            recommendations+=("Verify secrets are configured correctly")
        fi
        if grep -qiE "flaky|intermittent|sometimes fails" "$LOGS_DIR"/*.log 2>/dev/null; then
            failure_type="flaky"
            recommendations+=("Identify and fix non-deterministic behavior")
        fi
    fi

    # Generate report
    cat > "$report_file" << EOF
# Pipeline Debug Report

**Date**: $(date -Iseconds)
**Platform**: $PLATFORM
**Pipeline ID**: #${PIPELINE_ID}

---

## Failed Jobs

$(echo "$FAILED_JOBS_DATA" | jq -r '.[] | "- \(.name) (ID: \(.id))"')

---

## Failure Type

**Category**: ${failure_type}

---

## Error Excerpts

\`\`\`
$(for log_file in "$LOGS_DIR"/*.log; do
    if [[ -f "$log_file" ]]; then
        echo "=== $(basename "$log_file" .log) ==="
        grep -iE "error|failed|fatal" "$log_file" 2>/dev/null | tail -10 || echo "No errors found"
        echo ""
    fi
done)
\`\`\`

---

## Recommendations

$(if [[ ${#recommendations[@]} -gt 0 ]]; then
    printf '%s\n' "${recommendations[@]}" | nl -w1 -s'. '
else
    echo "No specific recommendations - review logs above"
fi)

---

## Root Cause Analysis

### Likely Cause

$(case "$failure_type" in
    dependency) echo "Missing or incompatible dependency" ;;
    test) echo "Code change broke existing tests" ;;
    lint) echo "Code style/formatting issues" ;;
    build) echo "Docker build or compilation error" ;;
    timeout) echo "Job exceeded time limit" ;;
    resource) echo "Insufficient memory or disk space" ;;
    auth) echo "Missing or invalid credentials" ;;
    flaky) echo "Non-deterministic test behavior" ;;
    *) echo "Unknown - review full logs" ;;
esac)

### How to Fix

$(case "$failure_type" in
    dependency)
        cat << 'FIX'
1. Check dependency versions in requirements.txt/package.json
2. Verify lockfiles are committed
3. Test locally: \`pip install -r requirements.txt\`
4. Check for platform-specific dependencies
FIX
        ;;
    test)
        cat << 'FIX'
1. Run tests locally: \`make test\`
2. Identify failing test from logs
3. Debug specific test: \`pytest path/to/test.py::test_name -vv\`
4. Fix code or update test
5. Verify all tests pass before committing
FIX
        ;;
    lint)
        cat << 'FIX'
1. Run linter locally: \`make lint\`
2. Auto-fix: \`make format\` or \`ruff check --fix .\`
3. Review remaining issues
4. Update code to match style guide
FIX
        ;;
    build)
        cat << 'FIX'
1. Test build locally: \`docker build .\`
2. Check Dockerfile for syntax errors
3. Verify all files referenced in COPY/ADD exist
4. Check base image is accessible
5. Review build args and environment variables
FIX
        ;;
    timeout)
        cat << 'FIX'
1. Identify slow operation in logs
2. Optimize slow operations
3. Or increase timeout in pipeline config
FIX
        ;;
    auth)
        cat << 'FIX'
1. Verify secrets are configured in CI/CD settings
2. Check secret names match pipeline variables
3. Verify token/key hasn't expired
4. Check repository/registry permissions
FIX
        ;;
    *)
        echo "Review full logs in ${LOGS_DIR}/"
        ;;
esac)

---

## Prevention

To prevent this failure in the future:

- Run checks locally before pushing: \`make lint test\`
- Use pre-commit hooks
- Test Docker builds locally
- Keep dependencies updated
- Monitor pipeline trends

---

## Full Logs

Complete logs saved to: \`${LOGS_DIR}/\`

EOF

    log "${GREEN}✓${NC} Report generated: $report_file"

    # If running only this section, return now
    if [[ "$SECTION" == "report" ]]; then
        local recommendations_json=$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .)
        local extra_json=$(cat <<EOF
"platform": "$PLATFORM",
  "pipeline_id": "$PIPELINE_ID",
  "failed_jobs": $FAILED_JOBS_DATA,
  "failure_type": "$failure_type",
  "recommendations": $recommendations_json,
  "report_file": "$report_file",
  "logs_directory": "$LOGS_DIR"
EOF
)
        exit_with_json "success" "Debug report generated" "" "$extra_json"
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
            --detect) SECTION="detect"; shift ;;
            --jobs) SECTION="jobs"; shift ;;
            --logs) SECTION="logs"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            --*) shift ;;  # Ignore unknown flags
            *)
                # Assume it's the pipeline ID
                PIPELINE_ID="$1"
                shift
                ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        detect)
            section_detect
            ;;
        jobs)
            section_detect  # Need platform and pipeline ID
            section_jobs
            ;;
        logs)
            section_detect
            section_jobs
            section_logs
            ;;
        analyze)
            section_detect
            section_jobs
            section_logs
            section_analyze
            ;;
        report)
            section_detect
            section_jobs
            section_logs
            section_analyze
            section_report
            ;;
        full)
            section_detect
            section_jobs
            section_logs
            section_analyze
            section_report

            # Full success - return complete results
            local recommendations_json=$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
            local extra_json=$(cat <<EOF
"platform": "$PLATFORM",
  "pipeline_id": "$PIPELINE_ID",
  "failed_jobs": $FAILED_JOBS_DATA,
  "failure_type": "$failure_type",
  "recommendations": $recommendations_json,
  "report_file": "${report_dir}/$(date +%Y-%m-%d)-debug-report.md",
  "logs_directory": "$LOGS_DIR"
EOF
)
            exit_with_json "success" "Pipeline debugging complete" "" "$extra_json"
            ;;
    esac
}

# Run main function
main "$@"

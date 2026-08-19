#!/usr/bin/env bash
set -euo pipefail

# test-run.sh - Run tests with coverage tracking and clear reporting
#
# Usage:
#   test-run.sh [--json|--raw] [--full|--detect|--run|--coverage|--parse]
#   Options: --coverage-flag --verbose --failed --pattern <pat> --file <path>
#
# State dir: each invocation gets its own unique TMP_DIR (mktemp -d) so
# concurrent sessions/worktrees never clobber each other. --full is
# self-contained (detect+run+parse in one process) and auto-cleans on exit.
# To chain separate --detect/--run/--parse calls, export TEST_RUN_DIR to a
# dir you own before each call; the script will reuse it and will NOT
# auto-delete it (you're responsible for `rm -rf "$TEST_RUN_DIR"` when done).

OUTPUT_MODE="json"; SECTION="full"
COVERAGE_FLAG=false; VERBOSE_FLAG=false; FAILED_FLAG=false
TEST_PATTERN=""; TEST_FILE=""
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/yaml.sh
source "$SCRIPT_DIR/lib/yaml.sh"

# Per-invocation state dir. Each process gets its own unique dir so
# concurrent sessions/worktrees never clobber each other. When --detect,
# --run, and --parse are invoked as separate processes (not --full), the
# caller must pass the dir along via TEST_RUN_DIR so later steps can find
# the state written by earlier steps; that dir is only cleaned up by the
# process that created it (i.e. the --full run, or a manually-set --detect
# run once the caller is done with it).
_CREATED_TMP_DIR=false
if [[ -n "${TEST_RUN_DIR:-}" ]]; then
    TMP_DIR="$TEST_RUN_DIR"
    mkdir -p "$TMP_DIR"
else
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-run.XXXXXX")
    _CREATED_TMP_DIR=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --detect) SECTION="detect"; shift ;;
        --run) SECTION="run"; shift ;;
        --coverage) SECTION="coverage"; shift ;;
        --parse) SECTION="parse"; shift ;;
        --coverage-flag|-c) COVERAGE_FLAG=true; shift ;;
        --verbose|-v) VERBOSE_FLAG=true; shift ;;
        --failed|-f) FAILED_FLAG=true; shift ;;
        --pattern) TEST_PATTERN="$2"; shift 2 ;;
        --file) TEST_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log() { [[ "$OUTPUT_MODE" == "raw" ]] && echo "$@" >&2; }

# Only the process that created TMP_DIR cleans it up. When a caller passes
# TEST_RUN_DIR to chain separate --detect/--run/--parse invocations, cleanup
# is the caller's responsibility (rm -rf "$TEST_RUN_DIR" once done).
[[ "$_CREATED_TMP_DIR" == "true" ]] && trap 'rm -rf "$TMP_DIR"' EXIT

#------------------------------------------------------------------------------
# Make delegation - use Makefile when available
#------------------------------------------------------------------------------

try_make_delegation() {
    # Check if a Makefile with FORMAT=json support exists
    if [[ ! -f "${PROJECT_ROOT}/Makefile" ]]; then
        return 1
    fi

    # Verify the Makefile supports FORMAT=json
    if ! make -n test FORMAT=json -C "${PROJECT_ROOT}" >/dev/null 2>&1; then
        return 1
    fi

    log "Delegating to make test FORMAT=json..."

    # Build ARGS for passthrough
    local make_args=""
    [[ -n "$TEST_FILE" ]] && make_args="--file $TEST_FILE"
    [[ -n "$TEST_PATTERN" ]] && make_args="$make_args -k $TEST_PATTERN"
    [[ "$VERBOSE_FLAG" == "true" ]] && make_args="$make_args -v"
    [[ "$FAILED_FLAG" == "true" ]] && make_args="$make_args --lf"
    [[ "$COVERAGE_FLAG" == "true" ]] && make_args="$make_args --cov --cov-report=term-missing"

    local make_output
    local make_exit=0
    make_output=$(make -C "${PROJECT_ROOT}" test FORMAT=json ARGS="$make_args" 2>&1) || make_exit=$?

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo "$make_output"
    else
        echo "$make_output" >&2
    fi
    exit $make_exit
}

output_json() {
    local status="$1" section="$2" message="$3"; shift 3
    local next_action
    case "$status" in
        success) next_action="display_summary" ;;
        error)   next_action="fix_error" ;;
        *)       next_action="display_summary" ;;
    esac
    local json="{\"status\":\"$status\",\"section\":\"$section\",\"message\":\"$message\",\"next_action\":\"$next_action\",\"timestamp\":\"$(date -Iseconds)\""
    while [[ $# -gt 0 ]]; do json="$json,\"$1\":\"$2\""; shift 2; done
    echo "${json}}"
}

error_exit() {
    local section="$1" message="$2" details="${3:-}"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo "{\"status\":\"error\",\"section\":\"$section\",\"message\":\"$message\",\"next_action\":\"fix_error\",\"details\":\"$details\",\"timestamp\":\"$(date -Iseconds)\"}"
    else echo "Error in $section: $message" >&2; [[ -n "$details" ]] && echo "Details: $details" >&2; fi
    exit 1
}

detect_framework() {
    log "Detecting test framework..."
    local framework="" test_command="" coverage_command="" min_coverage="80"
    if [[ -f "$PROJECT_ROOT/PROJECT.yaml" ]]; then
        test_command=$(yaml_get '.testing.command' "$PROJECT_ROOT/PROJECT.yaml")
        coverage_command=$(yaml_get '.testing.coverage_command' "$PROJECT_ROOT/PROJECT.yaml")
        min_coverage=$(yaml_get_default '.testing.min_coverage' "80" "$PROJECT_ROOT/PROJECT.yaml")
        [[ -n "$test_command" ]] && framework="configured"
    fi
    if [[ -z "$framework" ]]; then
        [[ -f "$PROJECT_ROOT/requirements.txt" ]] && grep -q "pytest" "$PROJECT_ROOT/requirements.txt" && { framework="pytest"; test_command="pytest"; coverage_command="pytest --cov"; }
        [[ -f "$PROJECT_ROOT/package.json" ]] && grep -q '"jest"' "$PROJECT_ROOT/package.json" && { framework="jest"; test_command="npm test"; coverage_command="npm test -- --coverage"; }
        [[ -f "$PROJECT_ROOT/package.json" ]] && grep -q '"vitest"' "$PROJECT_ROOT/package.json" && { framework="vitest"; test_command="npm test"; coverage_command="npm test -- --coverage"; }
        [[ -f "$PROJECT_ROOT/go.mod" ]] && { framework="go"; test_command="go test ./..."; coverage_command="go test ./... -coverprofile=coverage.out"; }
        [[ -f "$PROJECT_ROOT/Cargo.toml" ]] && { framework="cargo"; test_command="cargo test"; coverage_command="cargo test"; }
    fi
    [[ -z "$framework" ]] && error_exit "detect" "Could not detect test framework" "No PROJECT.yaml testing config and no recognized test files"
    mkdir -p "$TMP_DIR"
    cat > "$TMP_DIR/config.json" <<EOF
{"framework":"$framework","test_command":"$test_command","coverage_command":"$coverage_command","min_coverage":$min_coverage,"tmp_dir":"$TMP_DIR"}
EOF
    [[ "$OUTPUT_MODE" == "json" ]] && cat "$TMP_DIR/config.json" || { log "Detected: $framework"; log "Command: $test_command"; }
}

run_tests() {
    log "Running tests..."
    [[ ! -f "$TMP_DIR/config.json" ]] && error_exit "run" "No test config found" "Run --detect first"
    local framework=$(grep -o '"framework":"[^"]*"' "$TMP_DIR/config.json" | cut -d'"' -f4)
    local test_command=$(grep -o '"test_command":"[^"]*"' "$TMP_DIR/config.json" | cut -d'"' -f4)
    local coverage_command=$(grep -o '"coverage_command":"[^"]*"' "$TMP_DIR/config.json" | cut -d'"' -f4)
    local cmd="$test_command"
    [[ "$COVERAGE_FLAG" == "true" ]] && cmd="$coverage_command"
    local running_services=$(docker compose ps --filter "status=running" --format "{{.Service}}" 2>/dev/null || echo "")
    [[ -z "$running_services" ]] && error_exit "run" "Docker services not running" "Run 'make up' first"
    local test_service=""
    echo "$running_services" | grep -q "^backend$" && test_service="backend"
    echo "$running_services" | grep -q "^app$" && [[ -z "$test_service" ]] && test_service="app"
    [[ -z "$test_service" ]] && test_service=$(echo "$running_services" | head -1)
    local full_cmd="$cmd"
    case "$framework" in
        pytest)
            [[ "$VERBOSE_FLAG" == "true" ]] && full_cmd="$full_cmd -v"
            [[ "$FAILED_FLAG" == "true" ]] && full_cmd="$full_cmd --lf"
            [[ -n "$TEST_PATTERN" ]] && full_cmd="$full_cmd -k $TEST_PATTERN"
            [[ -n "$TEST_FILE" ]] && full_cmd="$full_cmd $TEST_FILE"
            [[ "$COVERAGE_FLAG" == "true" ]] && full_cmd="$full_cmd --cov-report=term-missing --cov-report=html:htmlcov"
            ;;
        jest|vitest)
            [[ "$VERBOSE_FLAG" == "true" ]] && full_cmd="$full_cmd --verbose"
            [[ "$FAILED_FLAG" == "true" ]] && full_cmd="$full_cmd --onlyFailures"
            [[ -n "$TEST_PATTERN" ]] && full_cmd="$full_cmd --testNamePattern=$TEST_PATTERN"
            [[ -n "$TEST_FILE" ]] && full_cmd="$full_cmd $TEST_FILE"
            ;;
        go)
            [[ "$VERBOSE_FLAG" == "true" ]] && full_cmd="$full_cmd -v"
            [[ -n "$TEST_PATTERN" ]] && full_cmd="$full_cmd -run $TEST_PATTERN"
            ;;
    esac
    local exit_code=0
    docker compose exec -T "$test_service" sh -c "$full_cmd" > "$TMP_DIR/output.txt" 2>&1 || exit_code=$?
    echo "$exit_code" > "$TMP_DIR/exit_code.txt"
    [[ "$OUTPUT_MODE" == "json" ]] && output_json "success" "run" "Tests executed" "exit_code" "$exit_code" || { cat "$TMP_DIR/output.txt"; log "Exit: $exit_code"; }
}

parse_results() {
    log "Parsing test results..."
    [[ ! -f "$TMP_DIR/config.json" ]] && error_exit "parse" "No test config found" "Run --detect first"
    [[ ! -f "$TMP_DIR/output.txt" ]] && error_exit "parse" "No test output found" "Run --run first"
    local framework=$(grep -o '"framework":"[^"]*"' "$TMP_DIR/config.json" | cut -d'"' -f4)
    local min_coverage=$(grep -o '"min_coverage":[0-9]*' "$TMP_DIR/config.json" | cut -d':' -f2)
    local exit_code=$(cat "$TMP_DIR/exit_code.txt")
    local output=$(cat "$TMP_DIR/output.txt")
    local total_tests=0 passed_tests=0 failed_tests=0 skipped_tests=0 duration="0s" coverage_pct="0"
    case "$framework" in
        pytest)
            echo "$output" | grep -q "passed" && passed_tests=$(echo "$output" | grep -o "[0-9]* passed" | grep -o "[0-9]*" || echo "0")
            echo "$output" | grep -q "failed" && failed_tests=$(echo "$output" | grep -o "[0-9]* failed" | grep -o "[0-9]*" || echo "0")
            echo "$output" | grep -q "skipped" && skipped_tests=$(echo "$output" | grep -o "[0-9]* skipped" | grep -o "[0-9]*" || echo "0")
            total_tests=$((passed_tests + failed_tests + skipped_tests))
            duration=$(echo "$output" | grep -o "in [0-9.]*s" | grep -o "[0-9.]*s" | head -1 || echo "0s")
            echo "$output" | grep -q "TOTAL" && coverage_pct=$(echo "$output" | grep "TOTAL" | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%' || echo "0")
            ;;
        jest|vitest)
            echo "$output" | grep -q "Tests:" && { passed_tests=$(echo "$output" | grep "Tests:" | grep -o "[0-9]* passed" | grep -o "[0-9]*" || echo "0"); failed_tests=$(echo "$output" | grep "Tests:" | grep -o "[0-9]* failed" | grep -o "[0-9]*" || echo "0"); total_tests=$(echo "$output" | grep "Tests:" | grep -o "[0-9]* total" | grep -o "[0-9]*" || echo "0"); }
            ;;
        go)
            echo "$output" | grep -q "^PASS$" && { passed_tests=1; failed_tests=0; } || { passed_tests=0; failed_tests=1; }
            total_tests=1
            echo "$output" | grep -q "coverage:" && coverage_pct=$(echo "$output" | grep "coverage:" | awk '{print $2}' | tr -d '%' || echo "0")
            ;;
    esac
    local status="success" message="All tests passed"
    [[ $exit_code -ne 0 || $failed_tests -gt 0 ]] && { status="error"; message="$failed_tests test(s) failed"; }
    [[ $skipped_tests -gt 0 && "$status" == "success" ]] && { status="error"; message="$skipped_tests test(s) skipped - not allowed"; }
    [[ "$COVERAGE_FLAG" == "true" && "$status" == "success" ]] && [[ $(awk -v a="$coverage_pct" -v b="$min_coverage" 'BEGIN{print (a<b)?1:0}') -eq 1 ]] && { status="error"; message="Coverage ${coverage_pct}% below minimum ${min_coverage}%"; }
    local next_action; [[ "$status" == "success" ]] && next_action="display_summary" || next_action="fix_error"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{"status":"$status","section":"parse","message":"$message","next_action":"$next_action","timestamp":"$(date -Iseconds)","total_tests":$total_tests,"passed_tests":$passed_tests,"failed_tests":$failed_tests,"skipped_tests":$skipped_tests,"duration":"$duration","coverage_pct":"$coverage_pct","min_coverage":$min_coverage,"exit_code":$exit_code}
EOF
    else
        echo "Status: $status | Tests: $passed_tests/$total_tests | Coverage: ${coverage_pct}%"
    fi
    [[ "$status" == "success" ]]
}

case "$SECTION" in
    full) try_make_delegation || { detect_framework; run_tests; parse_results; } ;;
    detect) detect_framework ;;
    run) run_tests ;;
    coverage) COVERAGE_FLAG=true; run_tests ;;
    parse) parse_results ;;
    *) error_exit "main" "Invalid section: $SECTION" ;;
esac

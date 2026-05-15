#!/usr/bin/env bash
# test_helper.bash - Shared BATS test helpers
# Load with: load test_helper

# Cache platform at load time to avoid repeated uname calls
_PLATFORM=$(uname -s)

# --- Temp Environment ---

common_setup() {
    TEST_DIR="$(mktemp -d)"
    TEST_BIN="${TEST_DIR}/bin"
    SCRIPTS_DIR="${BATS_TEST_DIRNAME}/.."
    FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
    ORIGINAL_PATH="$PATH"
    mkdir -p "$TEST_BIN"
    PATH="${TEST_BIN}:${PATH}"
    cd "$TEST_DIR"
}

common_teardown() {
    PATH="$ORIGINAL_PATH"
    cd "$BATS_TEST_DIRNAME" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

# --- Mock Generators ---

# Create a simple mock that outputs a fixed string
# Usage: create_mock "curl" '{"status":"ok"}'
#        create_mock "curl" '{"status":"ok"}' 1   # exit code 1
create_mock() {
    local cmd="$1"
    local output="${2:-}"
    local exit_code="${3:-0}"
    local datafile="${TEST_BIN}/.${cmd}.data"
    printf '%s' "$output" > "$datafile"
    cat > "${TEST_BIN}/${cmd}" <<MOCK
#!/usr/bin/env bash
cat "${datafile}"
echo
exit ${exit_code}
MOCK
    chmod +x "${TEST_BIN}/${cmd}"
}

# Create a mock that routes output based on arguments
# Usage: create_smart_mock "docker" \
#          "compose ps|||container_name" \
#          "compose up|||starting" \
#          "compose exec|||output"
create_smart_mock() {
    local cmd="$1"
    shift
    local case_idx=0
    local cases=""
    for mapping in "$@"; do
        local pattern="${mapping%%|||*}"
        local output="${mapping#*|||}"
        local datafile="${TEST_BIN}/.${cmd}.smart.${case_idx}"
        printf '%s' "$output" > "$datafile"
        cases+="    *\"${pattern}\"*) cat \"${datafile}\"; echo ;;"$'\n'
        case_idx=$((case_idx + 1))
    done

    cat > "${TEST_BIN}/${cmd}" <<MOCK
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
${cases}    *) echo "mock ${cmd}: unhandled args: \$ARGS" >&2; exit 1 ;;
esac
MOCK
    chmod +x "${TEST_BIN}/${cmd}"
}

# Create a mock that records all calls to a log file
# Usage: create_recording_mock "git"
#        run some_script
#        assert_mock_called "git" "commit"
create_recording_mock() {
    local cmd="$1"
    local output="${2:-}"
    local exit_code="${3:-0}"
    local logfile="${TEST_DIR}/.mock_calls_${cmd}"
    local datafile="${TEST_BIN}/.${cmd}.rec.data"
    : > "$logfile"
    printf '%s' "$output" > "$datafile"

    cat > "${TEST_BIN}/${cmd}" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "${logfile}"
cat "${datafile}"
echo
exit ${exit_code}
MOCK
    chmod +x "${TEST_BIN}/${cmd}"
}

# Assert a recording mock was called with specific args
# Usage: assert_mock_called "git" "commit"
assert_mock_called() {
    local cmd="$1"
    local pattern="$2"
    local logfile="${TEST_DIR}/.mock_calls_${cmd}"
    if [[ ! -f "$logfile" ]]; then
        echo "Mock $cmd was never called" >&2
        return 1
    fi
    if ! grep -qF "$pattern" "$logfile"; then
        echo "Mock $cmd was not called with pattern '$pattern'" >&2
        echo "Actual calls:" >&2
        cat "$logfile" >&2
        return 1
    fi
}

# Assert a recording mock was NOT called with specific args
assert_mock_not_called() {
    local cmd="$1"
    local pattern="$2"
    local logfile="${TEST_DIR}/.mock_calls_${cmd}"
    if [[ ! -f "$logfile" ]]; then
        return 0
    fi
    if grep -qF "$pattern" "$logfile"; then
        echo "Mock $cmd was unexpectedly called with pattern '$pattern'" >&2
        return 1
    fi
}

# Assert a recording mock was called exactly N times
assert_mock_call_count() {
    local cmd="$1"
    local expected="$2"
    local logfile="${TEST_DIR}/.mock_calls_${cmd}"
    local actual=0
    if [[ -f "$logfile" ]]; then
        actual=$(wc -l < "$logfile" | tr -d ' ')
    fi
    if [[ "$actual" -ne "$expected" ]]; then
        echo "Mock $cmd called $actual times, expected $expected" >&2
        if [[ -f "$logfile" ]]; then
            echo "Calls:" >&2
            cat "$logfile" >&2
        fi
        return 1
    fi
}

# Get the Nth call (0-indexed) from a recording mock
assert_mock_call_order() {
    local cmd="$1"
    local call_index="$2"
    local pattern="$3"
    local logfile="${TEST_DIR}/.mock_calls_${cmd}"
    if [[ ! -f "$logfile" ]]; then
        echo "Mock $cmd was never called" >&2
        return 1
    fi
    local total
    total=$(wc -l < "$logfile" | tr -d ' ')
    if [[ $((call_index + 1)) -gt "$total" ]]; then
        echo "Call #$call_index out of bounds: $cmd was only called $total time(s)" >&2
        return 1
    fi
    local line
    line=$(sed -n "$((call_index + 1))p" "$logfile")
    if [[ ! "$line" =~ $pattern ]]; then
        echo "Call #$call_index to $cmd was '$line', expected pattern '$pattern'" >&2
        return 1
    fi
}

# --- Fixture Helpers ---

# Copy a fixture YAML as PROJECT.yaml in the current test dir
# Usage: setup_mock_project "complete"     # copies complete.yaml
#        setup_mock_project "complete-gitlab"
setup_mock_project() {
    local fixture_name="$1"
    cp "${FIXTURES_DIR}/${fixture_name}.yaml" "${TEST_DIR}/PROJECT.yaml"
}

# Create a real git repo in the test dir
setup_mock_git_repo() {
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "init" > README.md
    git add README.md
    git commit -q -m "initial commit"
}

# Create a task branch with optional task files
# Usage: setup_task_branch "A3F2B9" "fix-login-bug"
setup_task_branch() {
    local task_id="$1"
    local description="${2:-task-description}"
    setup_mock_git_repo
    git checkout -q -b "feature/${task_id}-${description}"
}

# --- JSON Assertions ---

# Assert output is valid JSON
assert_valid_json() {
    local json="$1"
    if ! echo "$json" | jq . >/dev/null 2>&1; then
        echo "Not valid JSON: $json" >&2
        return 1
    fi
}

# Assert a JSON field equals an expected value
# Usage: assert_json_field "$output" ".status" "success"
assert_json_field() {
    local json="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual=$(echo "$json" | jq -r "$path" 2>/dev/null)
    if [[ "$actual" != "$expected" ]]; then
        echo "JSON field $path: expected '$expected', got '$actual'" >&2
        return 1
    fi
}

# Assert a JSON field is present (not null or missing)
assert_json_field_present() {
    local json="$1"
    local path="$2"
    local actual
    actual=$(echo "$json" | jq -r "$path" 2>/dev/null)
    if [[ -z "$actual" || "$actual" == "null" ]]; then
        echo "JSON field $path is missing or null" >&2
        return 1
    fi
}

# Assert standard JSON response structure (status + next_action + message)
assert_standard_json_response() {
    local json="$1"
    assert_valid_json "$json"
    assert_json_field_present "$json" ".status"
    assert_json_field_present "$json" ".next_action"
    assert_json_field_present "$json" ".message"
}

# Assert JSON field matches a regex pattern
assert_json_field_matches() {
    local json="$1"
    local path="$2"
    local pattern="$3"
    local actual
    actual=$(echo "$json" | jq -r "$path" 2>/dev/null)
    if [[ ! "$actual" =~ $pattern ]]; then
        echo "JSON field $path: '$actual' does not match pattern '$pattern'" >&2
        return 1
    fi
}

# --- Cross-Platform Helpers ---

is_macos() { [[ "$_PLATFORM" == "Darwin" ]]; }
is_linux() { [[ "$_PLATFORM" == "Linux" ]]; }

# Skip test on a specific platform
skip_on_macos() { is_macos && skip "Test not applicable on macOS"; }
skip_on_linux() { is_linux && skip "Test not applicable on Linux"; }

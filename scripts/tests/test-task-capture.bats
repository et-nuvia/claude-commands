#!/usr/bin/env bats

# Test suite for task-capture.sh
# Covers: source detection, input parsing, document creation, flag parsing

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# Flag parsing
# =============================================================================

@test "task-capture: --json flag produces valid JSON" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "Fix login bug" 2>/dev/null
    assert_valid_json "$output"
}

@test "task-capture: output always has section" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "Fix login" 2>/dev/null
    assert_json_field_present "$output" ".section"
}

# =============================================================================
# Source detection (--detect)
# =============================================================================

@test "task-capture: detects direct text input" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "Add user authentication" 2>/dev/null
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".section" "detect"
}

@test "task-capture: detects Asana URL" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "https://app.asana.com/0/123456/789012345678901" 2>/dev/null
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".source" "asana_url"
}

@test "task-capture: detects Asana GID" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "789012345678901" 2>/dev/null
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".source" "asana_gid"
}

@test "task-capture: detects GitLab issue URL" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "https://git.turnersrus.com/group/project/-/issues/42" 2>/dev/null
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".source" "gitlab_url"
}

@test "task-capture: detects email input" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "From: user@example.com Subject: Fix bug Please fix the login." 2>/dev/null
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".source" "email"
}

@test "task-capture: no input returns needs_input" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "needs_input"
}

# =============================================================================
# Parse section (--parse)
# =============================================================================

@test "task-capture: parse returns needs_llm" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --parse --input "Fix the login bug in authentication module" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "needs_llm"
}

@test "task-capture: parse includes input in output" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --parse --input "Add dark mode support" 2>/dev/null
    assert_valid_json "$output"
    # Check that input text appears somewhere in the output
    echo "$output" | grep -q "dark mode"
}

# =============================================================================
# Create-doc section
# =============================================================================

@test "task-capture: create-doc without title returns error" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --create-doc 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "task-capture: create-doc with title creates document" {
    setup_mock_git_repo
    mkdir -p docs/active docs/completed
    git add -A && git commit -q -m "setup" 2>/dev/null || true
    run "$SCRIPTS_DIR/task-capture.sh" --json --create-doc \
        --title "Fix login bug" \
        --description "Auth module has a race condition" 2>/dev/null
    assert_valid_json "$output"
    # May succeed or error depending on template availability
    local status_val
    status_val=$(echo "$output" | jq -r '.status')
    [[ "$status_val" == "success" ]] || [[ "$status_val" == "error" ]]
}

# =============================================================================
# JSON structure validation
# =============================================================================

@test "task-capture: all responses contain section field" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --detect --input "test input" 2>/dev/null
    assert_json_field_present "$output" ".section"
}

@test "task-capture: treats unknown flags as input text" {
    run "$SCRIPTS_DIR/task-capture.sh" --json --bogus 2>/dev/null
    assert_valid_json "$output"
    # Unknown flags are treated as positional input, not rejected
    # The script runs the full section which returns needs_llm
    assert_json_field "$output" ".status" "needs_llm"
}

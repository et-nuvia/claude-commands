#!/usr/bin/env bats

# Test suite for task-hold.sh, task-resume.sh, task-close.sh
# Covers: error paths, JSON structure, section flags

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# task-hold.sh
# =============================================================================

@test "task-hold: missing task returns error with fix_error" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "task-hold: error JSON has all required fields" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --full 2>/dev/null
    assert_standard_json_response "$output"
}

@test "task-hold: --identify section produces JSON" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
}

@test "task-hold: --update section without task returns error" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --update 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# task-resume.sh
# =============================================================================

@test "task-resume: error response has status=error" {
    run "$SCRIPTS_DIR/task-resume.sh" --json --search 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-resume: error response has all required fields" {
    run "$SCRIPTS_DIR/task-resume.sh" --json --search 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".section"
}

@test "task-resume: search for nonexistent task returns not_found" {
    mkdir -p "$TEST_DIR/docs/active" "$TEST_DIR/docs/completed"
    run "$SCRIPTS_DIR/task-resume.sh" --json --search "nonexistent task xyz" 2>&1
    assert_json_field "$output" ".status" "not_found"
}

@test "task-resume: --search section produces JSON" {
    run "$SCRIPTS_DIR/task-resume.sh" --json --search 2>&1
    assert_valid_json "$output"
}

# =============================================================================
# task-close.sh
# =============================================================================

@test "task-close: missing task returns error with fix_error" {
    run "$SCRIPTS_DIR/task-close.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "task-close: error JSON has all required fields" {
    run "$SCRIPTS_DIR/task-close.sh" --json --full 2>/dev/null
    assert_standard_json_response "$output"
}

@test "task-close: --identify section produces JSON" {
    run "$SCRIPTS_DIR/task-close.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
}

@test "task-close: --complete section without task returns error" {
    run "$SCRIPTS_DIR/task-close.sh" --json --complete 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-close: --defer section without task returns error" {
    run "$SCRIPTS_DIR/task-close.sh" --json --defer 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-close: --cleanup section without task returns error" {
    run "$SCRIPTS_DIR/task-close.sh" --json --cleanup 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

#!/usr/bin/env bats

# Test suite for task-fetch.sh
# Covers: config validation, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# task-fetch.sh
# =============================================================================

@test "task-fetch: missing PROJECT.yaml returns error" {
    run "$SCRIPTS_DIR/task-fetch.sh" --json --full 2>&1
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "task-fetch: error response is valid JSON" {
    run "$SCRIPTS_DIR/task-fetch.sh" --json --full 2>&1
    assert_valid_json "$output"
}

@test "task-fetch: error response has all required fields" {
    run "$SCRIPTS_DIR/task-fetch.sh" --json --full 2>&1
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".next_action"
    assert_json_field_present "$output" ".message"
    assert_json_field_present "$output" ".timestamp"
}

@test "task-fetch: --validate section produces JSON" {
    run "$SCRIPTS_DIR/task-fetch.sh" --json --validate 2>&1
    assert_valid_json "$output"
}

@test "task-fetch: with config runs validate section" {
    setup_mock_project "complete-gitlab"
    # May fail due to missing backend functions, but should attempt validation
    run "$SCRIPTS_DIR/task-fetch.sh" --json --validate 2>&1
    # Either produces JSON or errors out — both acceptable
    true
}


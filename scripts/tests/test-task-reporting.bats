#!/usr/bin/env bats

# Test suite for task-summary.sh, task-code-review.sh, task-risk.sh, task-audit.sh
# Covers: error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# task-summary.sh
# =============================================================================

@test "task-summary: missing task returns error or intervention_needed" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --full 2>/dev/null
    status_val=$(echo "$output" | jq -r '.status')
    [[ "$status_val" == "error" ]] || [[ "$status_val" == "intervention_needed" ]]
}

@test "task-summary: JSON output is valid" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "task-summary: has section in response" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --full 2>/dev/null
    assert_json_field_present "$output" ".section"
}

@test "task-summary: error has status field" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --full 2>/dev/null
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# task-code-review.sh
# =============================================================================

@test "task-code-review: missing task returns error" {
    run "$SCRIPTS_DIR/task-code-review.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-code-review: error JSON has required fields" {
    run "$SCRIPTS_DIR/task-code-review.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}

# =============================================================================
# task-risk.sh
# =============================================================================

@test "task-risk: missing env returns error" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-risk.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-risk: invalid env returns error" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-risk.sh" --json --full --env invalid 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-risk: error JSON is valid" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-risk.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# task-audit.sh
# =============================================================================

@test "task-audit: missing task returns error" {
    run "$SCRIPTS_DIR/task-audit.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".status" "error"
}

@test "task-audit: error JSON has required fields" {
    run "$SCRIPTS_DIR/task-audit.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}


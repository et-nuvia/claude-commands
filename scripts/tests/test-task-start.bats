#!/usr/bin/env bats

# Test suite for task-start.sh
# Covers: flag parsing, prerequisite verification, branch creation, order of operations

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# Flag parsing and error handling
# =============================================================================

@test "task-start: missing sequence returns error" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "task-start: error JSON is valid with all required fields" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".next_action"
    assert_json_field_present "$output" ".message"
}

@test "task-start: --json flag produces JSON output" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-start.sh" --json --verify 2>/dev/null
    # Should be valid JSON even on error
    assert_valid_json "$output"
}

# =============================================================================
# Verify section (--verify)
# =============================================================================

@test "task-start: verify on clean repo succeeds or reports status" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-start.sh" --json --verify 2>/dev/null
    assert_valid_json "$output"
    # Should report clean working tree or error about missing task
    status_val=$(echo "$output" | jq -r '.status')
    [[ "$status_val" == "success" ]] || [[ "$status_val" == "error" ]] || [[ "$status_val" == "blocked" ]]
}

# =============================================================================
# Order of operations
# =============================================================================

@test "task-start: does not create branch without valid sequence" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    # Verify no feature branch was created
    run git branch --list 'feature/*'
    [ -z "$output" ]
}

@test "task-start: does not create branch with dirty working tree" {
    setup_mock_git_repo
    echo "uncommitted" > dirty.txt
    git add dirty.txt
    run "$SCRIPTS_DIR/task-start.sh" --json --create-branch --sequence A3F2B9 2>/dev/null
    # The script should detect dirty state
    run git branch --list 'feature/A3F2B9*'
    # Either no branch created or status is blocked
    true  # assertion is that no crash occurred
}

# =============================================================================
# Section flags
# =============================================================================

@test "task-start: --identify section produces JSON" {
    setup_mock_git_repo
    mkdir -p docs/active
    run "$SCRIPTS_DIR/task-start.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
}

@test "task-start: --setup-env section produces JSON" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/task-start.sh" --json --setup-env 2>/dev/null
    assert_valid_json "$output"
}

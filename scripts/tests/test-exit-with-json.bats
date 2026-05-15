#!/usr/bin/env bats

# Test suite: exit_with_json behavior across all scripts
#
# Purpose: Lock down the JSON output contract BEFORE extracting to shared library.
# Every script that defines exit_with_json() must:
#   1. Return valid JSON on stdout
#   2. Include status, next_action, message, timestamp fields
#   3. Return exit code 0 for success, non-zero for errors
#   4. Map status→next_action consistently
#
# This is the CRITICAL regression safety net for the refactoring.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo
}

teardown() {
    common_teardown
}

# =============================================================================
# Helper: test a script's error JSON output
# =============================================================================

# Runs a script with --json and verifies standard error response structure.
# Usage: assert_script_error_json "script.sh" "--json --full"
assert_script_error_json() {
    local script="$1"
    shift
    run "$SCRIPTS_DIR/$script" "$@" 2>/dev/null
    # Should be valid JSON even on error
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
    assert_json_field_present "$output" ".timestamp"
}

# =============================================================================
# task-start.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-start error returns valid JSON" {
    assert_script_error_json "task-start.sh" --json --full
}

@test "exit_with_json: task-start error has next_action" {
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    assert_json_field_present "$output" ".next_action"
}

@test "exit_with_json: task-start error maps to fix_error" {
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "exit_with_json: task-start error exit code is non-zero" {
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    [ "$status" -ne 0 ]
}

# =============================================================================
# task-continue.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-continue error returns valid JSON" {
    assert_script_error_json "task-continue.sh" --json --identify
}

@test "exit_with_json: task-continue error has next_action" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_json_field_present "$output" ".next_action"
}

@test "exit_with_json: task-continue includes section field" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".section" "identify"
}

# =============================================================================
# task-close.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-close error returns valid JSON" {
    assert_script_error_json "task-close.sh" --json --identify
}

@test "exit_with_json: task-close error has next_action" {
    run "$SCRIPTS_DIR/task-close.sh" --json --identify 2>/dev/null
    assert_json_field_present "$output" ".next_action"
}

# =============================================================================
# task-hold.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-hold error returns valid JSON" {
    assert_script_error_json "task-hold.sh" --json --full
}

@test "exit_with_json: task-hold error has next_action" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --full 2>/dev/null
    assert_json_field_present "$output" ".next_action"
}

# =============================================================================
# task-fetch.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-fetch error returns valid JSON" {
    assert_script_error_json "task-fetch.sh" --json --full
}

# =============================================================================
# task-audit.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-audit error returns valid JSON" {
    assert_script_error_json "task-audit.sh" --json --full
}

@test "exit_with_json: task-audit error has next_action" {
    run "$SCRIPTS_DIR/task-audit.sh" --json --full 2>/dev/null
    assert_json_field_present "$output" ".next_action"
}

# =============================================================================
# task-code-review.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-code-review error returns valid JSON" {
    assert_script_error_json "task-code-review.sh" --json --full
}

# =============================================================================
# task-risk.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-risk error returns valid JSON" {
    assert_script_error_json "task-risk.sh" --json --full
}

# =============================================================================
# task-summary.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-summary error returns valid JSON" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}

# =============================================================================
# git-commit.sh: exit_with_json
# =============================================================================

@test "exit_with_json: git-commit analyze returns valid JSON" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# git-merge.sh: exit_with_json
# =============================================================================

@test "exit_with_json: git-merge error returns valid JSON" {
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}

# =============================================================================
# task-plan.sh: exit_with_json
# =============================================================================

@test "exit_with_json: task-plan error returns valid JSON" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}

# =============================================================================
# plan-progress.sh: exit_with_json
# =============================================================================

@test "exit_with_json: plan-progress error returns valid JSON" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# add-dependency.sh: exit_with_json
# =============================================================================

@test "exit_with_json: add-dependency error returns valid JSON" {
    run "$SCRIPTS_DIR/add-dependency.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}

# =============================================================================
# review-implement.sh: exit_with_json
# =============================================================================

@test "exit_with_json: review-implement error returns valid JSON" {
    run "$SCRIPTS_DIR/review-implement.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".message"
}

# =============================================================================
# Cross-script: next_action mapping consistency
# =============================================================================

@test "next_action: error status always maps to fix_error across scripts" {
    local scripts=(
        "task-start.sh --json --full"
        "task-continue.sh --json --identify"
        "task-close.sh --json --identify"
        "task-hold.sh --json --full"
        "task-audit.sh --json --full"
    )

    for script_cmd in "${scripts[@]}"; do
        run $SCRIPTS_DIR/$script_cmd 2>/dev/null
        if [[ -n "$output" ]] && echo "$output" | jq . >/dev/null 2>&1; then
            local status_val=$(echo "$output" | jq -r '.status')
            local next_action=$(echo "$output" | jq -r '.next_action')
            if [[ "$status_val" == "error" ]]; then
                if [[ "$next_action" != "fix_error" ]]; then
                    echo "FAIL: $script_cmd has status=error but next_action=$next_action (expected fix_error)" >&2
                    return 1
                fi
            fi
        fi
    done
}

@test "next_action: timestamp field present in all error responses" {
    local scripts=(
        "task-start.sh --json --full"
        "task-continue.sh --json --identify"
        "task-close.sh --json --identify"
    )

    for script_cmd in "${scripts[@]}"; do
        run $SCRIPTS_DIR/$script_cmd 2>/dev/null
        if [[ -n "$output" ]] && echo "$output" | jq . >/dev/null 2>&1; then
            assert_json_field_present "$output" ".timestamp"
        fi
    done
}

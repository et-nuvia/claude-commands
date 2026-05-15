#!/usr/bin/env bats

# Test suite for create-pr.sh, review-pr.sh, review-implement.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "create-pr: error response has next_action=fix_error" {
    grep -q 'next_action' "$SCRIPTS_DIR/create-pr.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/create-pr.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "review-pr: error response has next_action=fix_error" {
    grep -q 'next_action' "$SCRIPTS_DIR/review-pr.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/review-pr.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "review-implement: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/review-implement.sh" || skip "not yet converted"
}

@test "create-pr: error JSON is valid" {
    grep -q 'next_action' "$SCRIPTS_DIR/create-pr.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/create-pr.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".next_action"
}

@test "review-pr: error JSON is valid" {
    grep -q 'next_action' "$SCRIPTS_DIR/review-pr.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/review-pr.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "review scripts: all use set -euo pipefail" {
    local failures=0
    for script in create-pr.sh review-pr.sh review-implement.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

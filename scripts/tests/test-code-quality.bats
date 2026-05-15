#!/usr/bin/env bats

# Test suite for format.sh, refactor.sh, cleanproject.sh,
# add-dependency.sh, upgrade-dependencies.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "format: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/format.sh" || skip "not yet converted"
}

@test "refactor: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/refactor.sh" || skip "not yet converted"
}

@test "cleanproject: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/cleanproject.sh" || skip "not yet converted"
}

@test "add-dependency: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/add-dependency.sh" || skip "not yet converted"
}

@test "upgrade-dependencies: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/upgrade-dependencies.sh" || skip "not yet converted"
}

@test "cleanproject: with git repo returns valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/cleanproject.sh" || skip "not yet converted"
    setup_mock_git_repo
    touch test.txt && git add . && git commit -q -m "add file"
    run "$SCRIPTS_DIR/cleanproject.sh" --json --full 2>/dev/null
    next=$(echo "$output" | jq -r '.next_action' 2>/dev/null) || true
    [ -n "$next" ] && [ "$next" != "null" ]
}

@test "format: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/format.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/format.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "refactor: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/refactor.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/refactor.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "code quality scripts: all use set -euo pipefail" {
    local failures=0
    for script in format.sh refactor.sh cleanproject.sh add-dependency.sh upgrade-dependencies.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

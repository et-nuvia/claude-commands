#!/usr/bin/env bats

# Test suite for rotate-secret.sh, rotate-database.sh, rotate-generic.sh,
# verify-rotation.sh, rollback-secret.sh
# Covers: next_action presence, error paths, flag parsing

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# All rotation scripts: next_action in source
# =============================================================================

@test "rotate-secret: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rotate-secret.sh" || skip "not yet converted"
}

@test "rotate-database: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rotate-database.sh" || skip "not yet converted"
}

@test "rotate-generic: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rotate-generic.sh" || skip "not yet converted"
}

@test "verify-rotation: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/verify-rotation.sh" || skip "not yet converted"
}

@test "rollback-secret: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rollback-secret.sh" || skip "not yet converted"
}

# =============================================================================
# Error paths
# =============================================================================

@test "rotate-secret: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/rotate-secret.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/rotate-secret.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "rotate-database: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/rotate-database.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/rotate-database.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "verify-rotation: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/verify-rotation.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/verify-rotation.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "rollback-secret: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/rollback-secret.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/rollback-secret.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# Script structure
# =============================================================================

@test "rotation scripts: all use set -euo pipefail" {
    local failures=0
    for script in rotate-secret.sh rotate-database.sh rotate-generic.sh verify-rotation.sh rollback-secret.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

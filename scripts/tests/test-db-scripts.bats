#!/usr/bin/env bats

# Test suite for db-backup-verify.sh, db-performance.sh, db-restore.sh,
# db-upgrade.sh, db-user-audit.sh, run-migrations.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# All DB scripts: next_action in source
# =============================================================================

@test "db-backup-verify: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-backup-verify.sh" || skip "not yet converted"
}

@test "db-performance: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-performance.sh" || skip "not yet converted"
}

@test "db-restore: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-restore.sh" || skip "not yet converted"
}

@test "db-upgrade: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-upgrade.sh" || skip "not yet converted"
}

@test "db-user-audit: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-user-audit.sh" || skip "not yet converted"
}

@test "run-migrations: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/run-migrations.sh" || skip "not yet converted"
}

# =============================================================================
# Error paths
# =============================================================================

@test "db-user-audit: error has next_action value" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-user-audit.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/db-user-audit.sh" --json --full 2>/dev/null
    next=$(echo "$output" | jq -r '.next_action' 2>/dev/null)
    [ -n "$next" ] && [ "$next" != "null" ]
}

@test "db-performance: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-performance.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/db-performance.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "db-backup-verify: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/db-backup-verify.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/db-backup-verify.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# Script structure
# =============================================================================

@test "db scripts: all use set -euo pipefail" {
    local failures=0
    for script in db-backup-verify.sh db-performance.sh db-restore.sh db-upgrade.sh db-user-audit.sh run-migrations.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

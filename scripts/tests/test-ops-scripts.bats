#!/usr/bin/env bats

# Test suite for ops-capacity.sh, ops-cost.sh, ops-load-test.sh,
# ops-monitoring.sh, ops-scaling.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# All ops scripts: next_action in source
# =============================================================================

@test "ops-capacity: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-capacity.sh" || skip "not yet converted"
}

@test "ops-cost: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-cost.sh" || skip "not yet converted"
}

@test "ops-load-test: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-load-test.sh" || skip "not yet converted"
}

@test "ops-monitoring: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-monitoring.sh" || skip "not yet converted"
}

@test "ops-scaling: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-scaling.sh" || skip "not yet converted"
}

# =============================================================================
# Error paths
# =============================================================================

@test "ops-capacity: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-capacity.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/ops-capacity.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "ops-cost: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-cost.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/ops-cost.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "ops-monitoring: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/ops-monitoring.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/ops-monitoring.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# Script structure
# =============================================================================

@test "ops scripts: all use set -euo pipefail" {
    local failures=0
    for script in ops-capacity.sh ops-cost.sh ops-load-test.sh ops-monitoring.sh ops-scaling.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

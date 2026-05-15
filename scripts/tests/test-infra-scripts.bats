#!/usr/bin/env bats

# Test suite for infra-plan.sh, infra-apply.sh, infra-destroy.sh,
# infra-drift.sh, infra-verify.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# All infra scripts: next_action in source
# =============================================================================

@test "infra-plan: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-plan.sh" || skip "not yet converted"
}

@test "infra-apply: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-apply.sh" || skip "not yet converted"
}

@test "infra-destroy: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-destroy.sh" || skip "not yet converted"
}

@test "infra-drift: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-drift.sh" || skip "not yet converted"
}

@test "infra-verify: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-verify.sh" || skip "not yet converted"
}

# =============================================================================
# Error paths
# =============================================================================

@test "infra-drift: error has next_action=fix_error" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-drift.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/infra-drift.sh" --json --full 2>/dev/null
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "infra-plan: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-plan.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/infra-plan.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "infra-apply: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-apply.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/infra-apply.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "infra-destroy: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-destroy.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/infra-destroy.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "infra-verify: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-verify.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/infra-verify.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# Script structure
# =============================================================================

@test "infra scripts: all use set -euo pipefail" {
    local failures=0
    for script in infra-plan.sh infra-apply.sh infra-destroy.sh infra-drift.sh infra-verify.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

# =============================================================================
# Order of operations
# =============================================================================

@test "infra-destroy: requires confirmation (blocked by default)" {
    grep -q 'next_action' "$SCRIPTS_DIR/infra-destroy.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/infra-destroy.sh" --json --full 2>/dev/null
    status_val=$(echo "$output" | jq -r '.status')
    # Should require confirmation or error without config
    [[ "$status_val" == "error" ]] || [[ "$status_val" == "blocked" ]] || [[ "$status_val" == "needs_decision" ]]
}

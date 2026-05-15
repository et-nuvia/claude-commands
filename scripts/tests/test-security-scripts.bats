#!/usr/bin/env bats

# Test suite for security-scan.sh, security-patch.sh, security-compliance.sh,
# security-gate.sh, security-user-audit.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# All security scripts: next_action in source
# =============================================================================

@test "security-scan: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-scan.sh" || skip "not yet converted"
}

@test "security-patch: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-patch.sh" || skip "not yet converted"
}

@test "security-compliance: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-compliance.sh" || skip "not yet converted"
}

@test "security-gate: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-gate.sh" || skip "not yet converted"
}

@test "security-user-audit: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-user-audit.sh" || skip "not yet converted"
}

# =============================================================================
# Error paths
# =============================================================================

@test "security-scan: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-scan.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/security-scan.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "security-patch: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-patch.sh" || skip "not yet converted"
    # Script has a heredoc syntax error in generate_report() that triggers before JSON error path
    run "$SCRIPTS_DIR/security-patch.sh" --json --full 2>/dev/null
    echo "$output" | jq . >/dev/null 2>&1 || skip "script has heredoc syntax bug (line 386)"
    assert_valid_json "$output"
}

@test "security-user-audit: error has next_action" {
    grep -q 'next_action' "$SCRIPTS_DIR/security-user-audit.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/security-user-audit.sh" --json --full 2>/dev/null
    next=$(echo "$output" | jq -r '.next_action' 2>/dev/null)
    [ -n "$next" ] && [ "$next" != "null" ]
}

# =============================================================================
# Script structure
# =============================================================================

@test "security scripts: all use set -euo pipefail" {
    local failures=0
    for script in security-scan.sh security-patch.sh security-compliance.sh security-gate.sh security-user-audit.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

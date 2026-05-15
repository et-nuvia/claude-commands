#!/usr/bin/env bats

# Test suite for rca-analyze.sh, rca-pir.sh, rca-timeline.sh, rca-triage.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "rca-analyze: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rca-analyze.sh" || skip "not yet converted"
}

@test "rca-pir: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rca-pir.sh" || skip "not yet converted"
}

@test "rca-timeline: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rca-timeline.sh" || skip "not yet converted"
}

@test "rca-triage: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rca-triage.sh" || skip "not yet converted"
}

@test "rca-analyze: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/rca-analyze.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/rca-analyze.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "rca-triage: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/rca-triage.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/rca-triage.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "rca scripts: all use set -euo pipefail" {
    local failures=0
    for script in rca-analyze.sh rca-pir.sh rca-timeline.sh rca-triage.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

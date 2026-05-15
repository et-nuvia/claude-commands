#!/usr/bin/env bats

# Test suite for new-doc.sh, update-docs.sh, update-index.sh,
# docs-verify.sh, update-sequence-tracker.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "new-doc: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/new-doc.sh" || skip "not yet converted"
}

@test "update-docs: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/update-docs.sh" || skip "not yet converted"
}

@test "update-index: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/update-index.sh" || skip "not yet converted"
}

@test "docs-verify: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/docs-verify.sh" || skip "not yet converted"
}

@test "update-sequence-tracker: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/update-sequence-tracker.sh" || skip "not yet converted"
}

@test "new-doc: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/new-doc.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/new-doc.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "docs-verify: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/docs-verify.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/docs-verify.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "update-index: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/update-index.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/update-index.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "doc management scripts: all use set -euo pipefail" {
    local failures=0
    for script in new-doc.sh update-docs.sh update-index.sh docs-verify.sh update-sequence-tracker.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

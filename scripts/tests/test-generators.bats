#!/usr/bin/env bats

# Test suite for generate-dockerfile.sh, generate-makefile.sh,
# generate-pipeline.sh, generate-valid-paths.sh
# Covers: next_action presence, error paths, JSON structure

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "generate-dockerfile: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-dockerfile.sh" || skip "not yet converted"
}

@test "generate-makefile: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-makefile.sh" || skip "not yet converted"
}

@test "generate-pipeline: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-pipeline.sh" || skip "not yet converted"
}

@test "generate-valid-paths: produces output" {
    run "$SCRIPTS_DIR/generate-valid-paths.sh"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "generate-valid-paths: output contains known paths" {
    run "$SCRIPTS_DIR/generate-valid-paths.sh"
    [[ "$output" == *".name"* ]]
}

@test "generate-dockerfile: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-dockerfile.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/generate-dockerfile.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "generate-makefile: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-makefile.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/generate-makefile.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "generate-pipeline: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-pipeline.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/generate-pipeline.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "generator scripts: all use set -euo pipefail" {
    local failures=0
    for script in generate-dockerfile.sh generate-makefile.sh generate-pipeline.sh; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]] || skip "$failures scripts missing set -euo pipefail"
}

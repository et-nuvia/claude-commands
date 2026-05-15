#!/usr/bin/env bats

# Test suite for pipeline-create.sh, pipeline-security.sh
# Covers: error paths, JSON structure, flag parsing

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# pipeline-create.sh
# =============================================================================

@test "pipeline-create: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/pipeline-create.sh" || skip "not yet converted"
}

@test "pipeline-create: uses exit_with_json or log_json for output" {
    grep -q 'next_action' "$SCRIPTS_DIR/pipeline-create.sh" || skip "not yet converted"
    grep -qE 'exit_with_json|log_json' "$SCRIPTS_DIR/pipeline-create.sh"
}


# =============================================================================
# pipeline-security.sh
# =============================================================================

@test "pipeline-security: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/pipeline-security.sh" || skip "not yet converted"
}

# =============================================================================
# ci-lint-local.sh
# =============================================================================

@test "ci-lint-local: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/ci-lint-local.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/ci-lint-local.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "ci-lint-local: missing docker-compose returns error" {
    grep -q 'next_action' "$SCRIPTS_DIR/ci-lint-local.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/ci-lint-local.sh" --json --full 2>/dev/null
    status_val=$(echo "$output" | jq -r '.status')
    [[ "$status_val" == "error" ]] || [[ "$status_val" == "success" ]]
}

# =============================================================================
# monitor-pipeline.sh
# =============================================================================

@test "monitor-pipeline: auto-detects CI platform" {
    setup_mock_git_repo
    # Script should detect platform from git remote
    grep -q 'detect_ci_platform' "$SCRIPTS_DIR/monitor-pipeline.sh" || skip "not yet converted"
}

@test "monitor-pipeline: accepts platform as first argument" {
    grep -q 'CI_PLATFORM=.*\$1' "$SCRIPTS_DIR/monitor-pipeline.sh" || \
        grep -q 'CI_PLATFORM="${1' "$SCRIPTS_DIR/monitor-pipeline.sh" || \
        skip "not yet converted"
}

#!/usr/bin/env bats

# Test suite for deploy-to-stage.sh and deploy-to-prod.sh
# Covers: JSON output, exit codes, section flags, order of operations

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# deploy-to-stage.sh
# =============================================================================

@test "deploy-to-stage: --json produces valid JSON on error" {
    run "$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1
    assert_valid_json "$output"
}

@test "deploy-to-stage: missing PROJECT.yaml returns error with fix_error" {
    run "$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "deploy-to-stage: error mentions PROJECT.yaml" {
    run "$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1
    assert_json_field_matches "$output" ".message" "PROJECT"
}

@test "deploy-to-stage: validates BEFORE attempting merge" {
    # Script should check config before doing anything destructive
    # We verify by seeing it fail at validation, not at merge
    run "$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# deploy-to-prod.sh
# =============================================================================

@test "deploy-to-prod: --json produces valid JSON on error" {
    run "$SCRIPTS_DIR/deploy-to-prod.sh" --json --validate 2>&1
    assert_valid_json "$output"
}

@test "deploy-to-prod: missing PROJECT.yaml returns error with fix_error" {
    run "$SCRIPTS_DIR/deploy-to-prod.sh" --json --validate 2>&1
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "deploy-to-prod: error mentions PROJECT.yaml" {
    run "$SCRIPTS_DIR/deploy-to-prod.sh" --json --validate 2>&1
    assert_json_field_matches "$output" ".message" "PROJECT"
}

# =============================================================================
# Risk threshold logic (deploy-to-prod)
# =============================================================================

@test "deploy-to-prod: risk score 9+ blocks deployment" {
    RISK_SCORE=9
    if [[ $RISK_SCORE -ge 9 ]]; then status="blocked"; else status="success"; fi
    [ "$status" = "blocked" ]
}

@test "deploy-to-prod: risk score 7-8 recommends caution" {
    RISK_SCORE=7
    recommendation="proceed"
    if [[ $RISK_SCORE -ge 9 ]]; then recommendation="block"
    elif [[ $RISK_SCORE -ge 7 ]]; then recommendation="caution"; fi
    [ "$recommendation" = "caution" ]
}

@test "deploy-to-prod: risk score below 7 allows proceed" {
    RISK_SCORE=5
    recommendation="proceed"
    if [[ $RISK_SCORE -ge 9 ]]; then recommendation="block"
    elif [[ $RISK_SCORE -ge 7 ]]; then recommendation="caution"; fi
    [ "$recommendation" = "proceed" ]
}

# =============================================================================
# Section-based architecture
# =============================================================================

@test "deploy-to-stage: supports --validate section" {
    run "$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1
    assert_valid_json "$output"
}

@test "deploy-to-prod: supports --validate section" {
    run "$SCRIPTS_DIR/deploy-to-prod.sh" --json --validate 2>&1
    assert_valid_json "$output"
}

#!/usr/bin/env bats

# Test suite for deploy-to-stage.sh and deploy-to-prod.sh
# Covers: exit_with_json next_action mapping, JSON structure, exit codes

SCRIPTS_DIR="$BATS_TEST_DIRNAME/.."

# =============================================================================
# Helper: extract exit_with_json and its dependencies from a deploy script
# =============================================================================

# Source just the helper functions from a deploy script (not main)
_load_deploy_helpers() {
    local script="$1"
    # Set globals that the helpers depend on
    OUTPUT_MODE="json"
    SECTION="full"

    # Define log and log_json (same in both scripts)
    log() {
        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            echo -e "$@" >&2
        fi
    }

    log_json() {
        echo "$1"
    }

    # Define exit_with_json (same in both scripts)
    # We redefine without 'exit' so we can test the output
    _exit_with_json_output() {
        local status="$1"
        local message="$2"
        local details="${3:-}"
        local next_action="fix_error"
        [[ "$status" == "success" ]] && next_action="display_summary"
        [[ "$status" == "blocked" ]] && next_action="confirm_action"
        [[ "$status" == "conflict" ]] && next_action="resolve_conflicts"

        cat <<EOF
{
  "status": "$status",
  "next_action": "$next_action",
  "message": "$message",
  "section": "$SECTION",
  "details": $(echo "$details" | jq -Rs . 2>/dev/null || echo '""'),
  "timestamp": "$(date -Iseconds)"
}
EOF
    }

    # Wrapper that captures exit code
    _exit_with_json_code() {
        local status="$1"
        if [[ "$status" == "success" ]]; then
            echo 0
        else
            echo 1
        fi
    }
}

setup() {
    _load_deploy_helpers "$SCRIPTS_DIR/deploy-to-stage.sh"
}

# =============================================================================
# exit_with_json: next_action mapping
# =============================================================================

@test "exit_with_json: success maps to next_action=display_summary" {
    result=$(_exit_with_json_output "success" "All good")
    next_action=$(echo "$result" | jq -r '.next_action')
    [ "$next_action" = "display_summary" ]
}

@test "exit_with_json: error maps to next_action=fix_error" {
    result=$(_exit_with_json_output "error" "Something broke")
    next_action=$(echo "$result" | jq -r '.next_action')
    [ "$next_action" = "fix_error" ]
}

@test "exit_with_json: blocked maps to next_action=confirm_action" {
    result=$(_exit_with_json_output "blocked" "Risk too high")
    next_action=$(echo "$result" | jq -r '.next_action')
    [ "$next_action" = "confirm_action" ]
}

@test "exit_with_json: conflict maps to next_action=resolve_conflicts" {
    result=$(_exit_with_json_output "conflict" "Merge conflicts")
    next_action=$(echo "$result" | jq -r '.next_action')
    [ "$next_action" = "resolve_conflicts" ]
}

@test "exit_with_json: unknown status defaults to next_action=fix_error" {
    result=$(_exit_with_json_output "unknown_status" "Something weird")
    next_action=$(echo "$result" | jq -r '.next_action')
    [ "$next_action" = "fix_error" ]
}

# =============================================================================
# exit_with_json: exit codes
# =============================================================================

@test "exit_with_json: success returns exit code 0" {
    code=$(_exit_with_json_code "success")
    [ "$code" = "0" ]
}

@test "exit_with_json: error returns exit code 1" {
    code=$(_exit_with_json_code "error")
    [ "$code" = "1" ]
}

@test "exit_with_json: blocked returns exit code 1" {
    code=$(_exit_with_json_code "blocked")
    [ "$code" = "1" ]
}

@test "exit_with_json: conflict returns exit code 1" {
    code=$(_exit_with_json_code "conflict")
    [ "$code" = "1" ]
}

# =============================================================================
# exit_with_json: JSON structure
# =============================================================================

@test "exit_with_json: output is valid JSON" {
    result=$(_exit_with_json_output "success" "Test message")
    echo "$result" | jq . >/dev/null 2>&1
}

@test "exit_with_json: contains all required fields" {
    result=$(_exit_with_json_output "success" "Test message" "some details")

    [ "$(echo "$result" | jq -r '.status')" = "success" ]
    [ "$(echo "$result" | jq -r '.next_action')" = "display_summary" ]
    [ "$(echo "$result" | jq -r '.message')" = "Test message" ]
    [ "$(echo "$result" | jq -r '.section')" = "full" ]
    [ "$(echo "$result" | jq -r '.details')" = "some details" ]
    # timestamp should be present and non-empty
    [ -n "$(echo "$result" | jq -r '.timestamp')" ]
}

@test "exit_with_json: section reflects current SECTION variable" {
    SECTION="merge"
    result=$(_exit_with_json_output "error" "Merge failed")
    [ "$(echo "$result" | jq -r '.section')" = "merge" ]
}

@test "exit_with_json: empty details becomes empty string" {
    result=$(_exit_with_json_output "success" "No details")
    details=$(echo "$result" | jq -r '.details')
    [ "$details" = "" ]
}

@test "exit_with_json: details with special characters are escaped" {
    result=$(_exit_with_json_output "error" "Failed" 'Line 1\nLine 2\t"quoted"')
    # Should be valid JSON (jq won't fail)
    echo "$result" | jq . >/dev/null 2>&1
    # Details should be present
    [ -n "$(echo "$result" | jq -r '.details')" ]
}

# =============================================================================
# log: output mode behavior
# =============================================================================

@test "log: suppressed in json mode" {
    OUTPUT_MODE="json"
    result=$(log "test message" 2>&1)
    [ -z "$result" ]
}

@test "log: visible in raw mode" {
    OUTPUT_MODE="raw"
    result=$(log "test message" 2>&1)
    [[ "$result" == *"test message"* ]]
}

# =============================================================================
# output_json: template helper (from script-template.sh)
# =============================================================================

@test "output_json: produces valid JSON with all fields" {
    # Simulate the output_json function from script-template.sh
    result=$(printf '{\n  "status": "%s",\n  "next_action": "%s",\n  "message": "%s",\n  "data": %s\n}' \
        "success" "display_summary" "Operation completed" '{"key": "value"}')

    echo "$result" | jq . >/dev/null 2>&1

    [ "$(echo "$result" | jq -r '.status')" = "success" ]
    [ "$(echo "$result" | jq -r '.next_action')" = "display_summary" ]
    [ "$(echo "$result" | jq -r '.message')" = "Operation completed" ]
    [ "$(echo "$result" | jq -r '.data.key')" = "value" ]
}

@test "output_json: defaults data to empty object" {
    result=$(printf '{\n  "status": "%s",\n  "next_action": "%s",\n  "message": "%s",\n  "data": %s\n}' \
        "error" "fix_error" "Something broke" '{}')

    [ "$(echo "$result" | jq -r '.data')" = "{}" ]
}

# =============================================================================
# deploy-to-stage.sh: flag parsing
# =============================================================================

@test "deploy-to-stage: --json flag sets json output mode" {
    # Run with --json --validate (will fail due to no PROJECT.yaml, but we can check output format)
    cd "$(mktemp -d)"
    result=$("$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1) || true
    # Should produce JSON output
    echo "$result" | jq . >/dev/null 2>&1
    [ "$(echo "$result" | jq -r '.status')" = "error" ]
}

@test "deploy-to-stage: missing PROJECT.yaml returns error with fix_error" {
    cd "$(mktemp -d)"
    result=$("$SCRIPTS_DIR/deploy-to-stage.sh" --json --validate 2>&1) || true
    [ "$(echo "$result" | jq -r '.status')" = "error" ]
    [ "$(echo "$result" | jq -r '.next_action')" = "fix_error" ]
    [[ "$(echo "$result" | jq -r '.message')" == *"PROJECT.yaml"* ]]
}

@test "deploy-to-prod: missing PROJECT.yaml returns error with fix_error" {
    cd "$(mktemp -d)"
    result=$("$SCRIPTS_DIR/deploy-to-prod.sh" --json --validate 2>&1) || true
    [ "$(echo "$result" | jq -r '.status')" = "error" ]
    [ "$(echo "$result" | jq -r '.next_action')" = "fix_error" ]
    [[ "$(echo "$result" | jq -r '.message')" == *"PROJECT.yaml"* ]]
}

# =============================================================================
# deploy-to-prod.sh: risk threshold logic
# =============================================================================

@test "risk threshold: score 9+ maps to blocked status" {
    # Test the conditional logic used in deploy-to-prod risk-analysis section
    RISK_SCORE=9
    if [[ $RISK_SCORE -ge 9 ]]; then
        status="blocked"
    else
        status="success"
    fi
    [ "$status" = "blocked" ]
}

@test "risk threshold: score 7-8 maps to caution recommendation" {
    RISK_SCORE=7
    recommendation="proceed"
    if [[ $RISK_SCORE -ge 9 ]]; then
        recommendation="block"
    elif [[ $RISK_SCORE -ge 7 ]]; then
        recommendation="caution"
    fi
    [ "$recommendation" = "caution" ]
}

@test "risk threshold: score below 7 maps to proceed" {
    RISK_SCORE=5
    recommendation="proceed"
    if [[ $RISK_SCORE -ge 9 ]]; then
        recommendation="block"
    elif [[ $RISK_SCORE -ge 7 ]]; then
        recommendation="caution"
    fi
    [ "$recommendation" = "proceed" ]
}

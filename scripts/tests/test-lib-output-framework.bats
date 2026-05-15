#!/usr/bin/env bats

# Test suite for lib/output-framework.sh
# Covers: log, log_json, exit_with_json, color constants, map_status_to_action

load test_helper

setup() {
    common_setup
    LIB_DIR="${SCRIPTS_DIR}/lib"
}

teardown() {
    common_teardown
}

# =============================================================================
# Color constants
# =============================================================================

@test "output-framework: defines all color constants" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo "$RED $GREEN $YELLOW $BLUE $CYAN $MAGENTA $NC"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"033"* ]]
}

@test "output-framework: does not override caller-defined colors" {
    run bash -c '
        RED="custom_red"
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo "$RED"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "custom_red" ]
}

# =============================================================================
# log()
# =============================================================================

@test "output-framework: log suppressed in json mode" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        log "should not appear"
    '
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "output-framework: log outputs to stderr in raw mode" {
    run bash -c '
        OUTPUT_MODE=raw SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        log "hello from raw" 2>&1
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"hello from raw"* ]]
}

@test "output-framework: log does not output to stdout in raw mode" {
    # Capture only stdout (not stderr)
    local stdout
    stdout=$(bash -c '
        OUTPUT_MODE=raw SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        log "stderr only"
    ' 2>/dev/null)
    [ -z "$stdout" ]
}

# =============================================================================
# log_json()
# =============================================================================

@test "output-framework: log_json outputs to stdout" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        log_json "{\"key\": \"value\"}"
    '
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".key" "value"
}

@test "output-framework: log_json works in raw mode too" {
    run bash -c '
        OUTPUT_MODE=raw SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        log_json "{\"mode\": \"raw\"}"
    '
    [ "$status" -eq 0 ]
    assert_json_field "$output" ".mode" "raw"
}

# =============================================================================
# Default next_action mapping
# =============================================================================

@test "output-framework: success maps to display_summary" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo $(map_status_to_action "success")
    '
    [ "$output" = "display_summary" ]
}

@test "output-framework: error maps to fix_error" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo $(map_status_to_action "error")
    '
    [ "$output" = "fix_error" ]
}

@test "output-framework: intervention_needed maps to fix_error" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo $(map_status_to_action "intervention_needed")
    '
    [ "$output" = "fix_error" ]
}

@test "output-framework: blocked maps to fix_error" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo $(map_status_to_action "blocked")
    '
    [ "$output" = "fix_error" ]
}

@test "output-framework: unknown status maps to fix_error" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo $(map_status_to_action "whatever")
    '
    [ "$output" = "fix_error" ]
}

# =============================================================================
# Custom next_action mapping
# =============================================================================

@test "output-framework: custom map_status_to_action is preserved" {
    run bash -c '
        map_status_to_action() {
            case "$1" in
                ready) echo "proceed_to_analysis" ;;
                *) echo "custom_fallback" ;;
            esac
        }
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        echo $(map_status_to_action "ready")
    '
    [ "$output" = "proceed_to_analysis" ]
}

@test "output-framework: custom mapping used by exit_with_json" {
    run bash -c '
        map_status_to_action() {
            case "$1" in
                ready) echo "proceed_to_analysis" ;;
                *) echo "custom_default" ;;
            esac
        }
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "ready" "Data collected"
    '
    [ "$status" -eq 0 ]
    assert_json_field "$output" ".next_action" "proceed_to_analysis"
}

# =============================================================================
# exit_with_json - basic
# =============================================================================

@test "output-framework: exit_with_json success exits 0" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "success" "All done"
    '
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".next_action" "display_summary"
    assert_json_field "$output" ".message" "All done"
}

@test "output-framework: exit_with_json error exits 1" {
    run bash -c '
        OUTPUT_MODE=json SECTION=identify
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "error" "Something broke"
    '
    [ "$status" -eq 1 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
    assert_json_field "$output" ".message" "Something broke"
    assert_json_field "$output" ".section" "identify"
}

@test "output-framework: exit_with_json includes timestamp" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "success" "Done"
    '
    assert_json_field_present "$output" ".timestamp"
}

@test "output-framework: exit_with_json includes section" {
    run bash -c '
        OUTPUT_MODE=json SECTION=my_section
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "error" "fail"
    '
    assert_json_field "$output" ".section" "my_section"
}

# =============================================================================
# exit_with_json - with details
# =============================================================================

@test "output-framework: exit_with_json with details" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "error" "Failed" "Stack trace here"
    '
    [ "$status" -eq 1 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".details" "Stack trace here"
}

@test "output-framework: exit_with_json empty details becomes empty string" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "success" "OK" ""
    '
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    local details
    details=$(echo "$output" | jq -r '.details')
    [ "$details" = "" ]
}

@test "output-framework: exit_with_json details with special chars" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "error" "Fail" "Line 1
Line 2 with \"quotes\" and \backslash"
    '
    [ "$status" -eq 1 ]
    assert_valid_json "$output"
    assert_json_field_present "$output" ".details"
}

# =============================================================================
# exit_with_json - with extra fields
# =============================================================================

@test "output-framework: exit_with_json with extra JSON fields" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "success" "Done" "" "\"count\": 5, \"items\": [\"a\", \"b\"]"
    '
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".count" "5"
    local items
    items=$(echo "$output" | jq -r '.items | length')
    [ "$items" -eq 2 ]
}

@test "output-framework: exit_with_json with details AND extra fields" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "error" "Merge failed" "conflict in file.txt" "\"conflicting_files\": [\"file.txt\"]"
    '
    [ "$status" -eq 1 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".details" "conflict in file.txt"
    assert_json_field_present "$output" ".conflicting_files"
}

@test "output-framework: exit_with_json variadic extra fields (multi-arg)" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "success" "Task done" "" \
            "\"task_id\": \"A1B2C3\"," \
            "\"task_title\": \"Fix bug\"," \
            "\"branch\": \"feature/test\""
    '
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".task_id" "A1B2C3"
    assert_json_field "$output" ".task_title" "Fix bug"
    assert_json_field "$output" ".branch" "feature/test"
}

# =============================================================================
# exit_with_json - all status types
# =============================================================================

@test "output-framework: intervention_needed exits 0" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "intervention_needed" "Need help"
    '
    [ "$status" -eq 0 ]
    assert_json_field "$output" ".status" "intervention_needed"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "output-framework: blocked exits 1" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "blocked" "Waiting on CI"
    '
    [ "$status" -eq 1 ]
    assert_json_field "$output" ".status" "blocked"
}

@test "output-framework: ready_for_* statuses exit 0" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "ready_for_opus" "Need Opus model"
    '
    [ "$status" -eq 0 ]
    assert_json_field "$output" ".status" "ready_for_opus"
}

@test "output-framework: requires_* statuses exit 0" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "requires_opus" "Opus required"
    '
    [ "$status" -eq 0 ]
    assert_json_field "$output" ".status" "requires_opus"
}

# =============================================================================
# Double-source guard
# =============================================================================

@test "output-framework: double-sourcing is safe" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "success" "Still works"
    '
    [ "$status" -eq 0 ]
    assert_json_field "$output" ".status" "success"
}

# =============================================================================
# Standard response structure
# =============================================================================

@test "output-framework: exit_with_json passes assert_standard_json_response" {
    run bash -c '
        OUTPUT_MODE=json SECTION=test
        source "'"$LIB_DIR"'/output-framework.sh"
        exit_with_json "error" "Something failed"
    '
    assert_standard_json_response "$output"
}

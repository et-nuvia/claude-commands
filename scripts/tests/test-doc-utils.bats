#!/usr/bin/env bats

# Test suite for doc-utils.sh
# Covers: find_docs_dir, find_by_sequence, find_primary, get_sequence, get_type,
#         get_datetime, parse_datetime, list_sequences, count_docs, sequence_exists,
#         get_status, find_by_issue_number, find_legacy_task

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/doc-utils.sh"

    # Create standard docs structure
    mkdir -p "$TEST_DIR/docs/active" "$TEST_DIR/docs/completed"
}

teardown() {
    common_teardown
}

# =============================================================================
# find_docs_dir
# =============================================================================

@test "find_docs_dir: finds docs in current directory" {
    result=$(find_docs_dir)
    [ "$result" = "$TEST_DIR/docs" ]
}

@test "find_docs_dir: finds docs in parent directory" {
    mkdir -p "$TEST_DIR/subdir"
    cd "$TEST_DIR/subdir"
    result=$(find_docs_dir)
    [ "$result" = "$TEST_DIR/docs" ]
}

@test "find_docs_dir: fails when no docs dir exists" {
    rm -rf "$TEST_DIR/docs"
    run find_docs_dir
    [ "$status" -ne 0 ]
}

@test "find_docs_dir: respects 5-level depth limit" {
    local deep="$TEST_DIR/a/b/c/d/e/f"
    mkdir -p "$deep"
    cd "$deep"
    run find_docs_dir
    [ "$status" -ne 0 ]
}

# =============================================================================
# get_sequence
# =============================================================================

@test "get_sequence: extracts 6-char hex from V4 filename" {
    result=$(get_sequence "A3F2B9-2602031430-INC-description.md")
    [ "$result" = "A3F2B9" ]
}

@test "get_sequence: returns empty for non-matching filename" {
    run get_sequence "some-other-file.md"
    [ -z "$output" ]
}

# =============================================================================
# get_type
# =============================================================================

@test "get_type: extracts INC type" {
    result=$(get_type "A3F2B9-2602031430-INC-description.md")
    [ "$result" = "INC" ]
}

@test "get_type: extracts TSK type" {
    result=$(get_type "A3F2B9-2602031430-TSK-description.md")
    [ "$result" = "TSK" ]
}

@test "get_type: extracts PLN type" {
    result=$(get_type "A3F2B9-2602031430-PLN-description.md")
    [ "$result" = "PLN" ]
}

@test "get_type: extracts CRV type" {
    result=$(get_type "A3F2B9-2602031430-CRV-description.md")
    [ "$result" = "CRV" ]
}

# =============================================================================
# get_datetime
# =============================================================================

@test "get_datetime: extracts 10-digit V4 datetime" {
    result=$(get_datetime "A3F2B9-2602031430-INC-description.md")
    [ "$result" = "2602031430" ]
}

@test "get_datetime: extracts 12-digit V3 datetime" {
    result=$(get_datetime "A3F2B9-202602031430-INC-description.md")
    [ "$result" = "202602031430" ]
}

# =============================================================================
# parse_datetime
# =============================================================================

@test "parse_datetime: parses 10-digit V4 format" {
    result=$(parse_datetime "2602031430")
    [ "$result" = "2026-02-03 14:30" ]
}

@test "parse_datetime: parses 12-digit V3 format" {
    result=$(parse_datetime "202602031430")
    [ "$result" = "2026-02-03 14:30" ]
}

@test "parse_datetime: handles midnight" {
    result=$(parse_datetime "2601010000")
    [ "$result" = "2026-01-01 00:00" ]
}

@test "parse_datetime: handles end of day" {
    result=$(parse_datetime "2612312359")
    [ "$result" = "2026-12-31 23:59" ]
}

# =============================================================================
# find_by_sequence
# =============================================================================

@test "find_by_sequence: finds documents in active" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-my-task.md"
    result=$(find_by_sequence "A3F2B9" "$TEST_DIR/docs")
    [[ "$result" == *"A3F2B9-2602031430-TSK-my-task.md"* ]]
}

@test "find_by_sequence: finds documents in completed" {
    touch "$TEST_DIR/docs/completed/A3F2B9-2602031430-TSK-my-task.md"
    result=$(find_by_sequence "A3F2B9" "$TEST_DIR/docs")
    [[ "$result" == *"A3F2B9-2602031430-TSK-my-task.md"* ]]
}

@test "find_by_sequence: finds multiple documents" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-my-task.md"
    touch "$TEST_DIR/docs/active/A3F2B9-2602031500-PLN-my-task.md"
    result=$(find_by_sequence "A3F2B9" "$TEST_DIR/docs")
    local count=$(echo "$result" | wc -l)
    [ "$count" -eq 2 ]
}

@test "find_by_sequence: normalizes lowercase to uppercase" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-my-task.md"
    result=$(find_by_sequence "a3f2b9" "$TEST_DIR/docs")
    [[ "$result" == *"A3F2B9"* ]]
}

@test "find_by_sequence: returns empty for non-existent sequence" {
    result=$(find_by_sequence "BBBBBB" "$TEST_DIR/docs")
    [ -z "$result" ]
}

# =============================================================================
# find_primary
# =============================================================================

@test "find_primary: finds TSK document" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-my-task.md"
    touch "$TEST_DIR/docs/active/A3F2B9-2602031500-PLN-my-task.md"
    result=$(find_primary "A3F2B9" "$TEST_DIR/docs")
    [[ "$result" == *"TSK"* ]]
}

@test "find_primary: finds INC document" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-INC-my-incident.md"
    result=$(find_primary "A3F2B9" "$TEST_DIR/docs")
    [[ "$result" == *"INC"* ]]
}

@test "find_primary: returns empty when no primary exists" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031500-PLN-my-task.md"
    result=$(find_primary "A3F2B9" "$TEST_DIR/docs")
    [ -z "$result" ]
}

# =============================================================================
# list_sequences
# =============================================================================

@test "list_sequences: lists active sequences" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-task-one.md"
    touch "$TEST_DIR/docs/active/BBBBBB-2602031430-TSK-task-two.md"
    result=$(list_sequences "active")
    [[ "$result" == *"A3F2B9"* ]]
    [[ "$result" == *"BBBBBB"* ]]
}

@test "list_sequences: lists completed sequences" {
    touch "$TEST_DIR/docs/completed/CCCCCC-2602031430-TSK-done.md"
    result=$(list_sequences "completed")
    [[ "$result" == *"CCCCCC"* ]]
}

@test "list_sequences: lists all sequences" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-active.md"
    touch "$TEST_DIR/docs/completed/CCCCCC-2602031430-TSK-done.md"
    result=$(list_sequences "all")
    [[ "$result" == *"A3F2B9"* ]]
    [[ "$result" == *"CCCCCC"* ]]
}

@test "list_sequences: deduplicates sequences with multiple docs" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-task.md"
    touch "$TEST_DIR/docs/active/A3F2B9-2602031500-PLN-task.md"
    result=$(list_sequences "active")
    local count=$(echo "$result" | grep -c "A3F2B9")
    [ "$count" -eq 1 ]
}

# =============================================================================
# count_docs / sequence_exists
# =============================================================================

@test "count_docs: counts documents for sequence" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-task.md"
    touch "$TEST_DIR/docs/active/A3F2B9-2602031500-PLN-task.md"
    result=$(count_docs "A3F2B9")
    [ "$result" -eq 2 ]
}

@test "count_docs: returns 0 for non-existent sequence" {
    result=$(count_docs "FFFFFF")
    [ "$result" -eq 0 ]
}

@test "sequence_exists: returns true for existing sequence" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-task.md"
    sequence_exists "A3F2B9"
}

@test "sequence_exists: returns false for non-existent sequence" {
    ! sequence_exists "FFFFFF"
}

# =============================================================================
# get_status
# =============================================================================

@test "get_status: returns active for docs in active/" {
    touch "$TEST_DIR/docs/active/A3F2B9-2602031430-TSK-task.md"
    result=$(get_status "A3F2B9")
    [ "$result" = "active" ]
}

@test "get_status: returns completed for docs in completed/" {
    touch "$TEST_DIR/docs/completed/A3F2B9-2602031430-TSK-task.md"
    result=$(get_status "A3F2B9")
    [ "$result" = "completed" ]
}

@test "get_status: returns unknown for non-existent sequence" {
    result=$(get_status "FFFFFF")
    [ "$result" = "unknown" ]
}

# =============================================================================
# find_legacy_task
# =============================================================================

@test "find_legacy_task: finds in tasks/ directory" {
    mkdir -p "$TEST_DIR/docs/tasks"
    touch "$TEST_DIR/docs/tasks/2026-02-03-bug-fix.md"
    result=$(find_legacy_task "2026-02-03-bug-fix.md" "$TEST_DIR/docs")
    [[ "$result" == *"2026-02-03-bug-fix.md"* ]]
}

@test "find_legacy_task: finds in tasks/completed/" {
    mkdir -p "$TEST_DIR/docs/tasks/completed"
    touch "$TEST_DIR/docs/tasks/completed/2026-02-03-done.md"
    result=$(find_legacy_task "2026-02-03-done.md" "$TEST_DIR/docs")
    [[ "$result" == *"2026-02-03-done.md"* ]]
}

@test "find_legacy_task: returns failure for non-existent" {
    run find_legacy_task "nonexistent.md" "$TEST_DIR/docs"
    [ "$status" -ne 0 ]
}

# =============================================================================
# find_by_issue_number
# =============================================================================

@test "find_by_issue_number: finds task by issue reference" {
    mkdir -p "$TEST_DIR/docs/active/A3F2B9"
    echo "Issue #42 - Fix login bug" > "$TEST_DIR/docs/active/A3F2B9/A3F2B9-2602031430-TSK-fix-login.md"
    result=$(find_by_issue_number "42")
    [ "$result" = "A3F2B9" ]
}

@test "find_by_issue_number: returns empty for unmatched issue" {
    run find_by_issue_number "99999"
    [ -z "$output" ]
}

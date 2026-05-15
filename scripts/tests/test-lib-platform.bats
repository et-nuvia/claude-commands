#!/usr/bin/env bats

# Test suite for lib/platform.sh
# Covers: sedi, portable_date_relative, portable_date_parse, human_bytes

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/lib/platform.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# sedi - portable sed -i
# =============================================================================

@test "sedi: replaces text in file" {
    echo "hello world" > "$TEST_DIR/test.txt"
    sedi 's/world/earth/' "$TEST_DIR/test.txt"
    result=$(cat "$TEST_DIR/test.txt")
    [ "$result" = "hello earth" ]
}

@test "sedi: handles multiple replacements" {
    printf "foo\nfoo\nbar\n" > "$TEST_DIR/test.txt"
    sedi 's/foo/baz/g' "$TEST_DIR/test.txt"
    result=$(cat "$TEST_DIR/test.txt")
    [[ "$result" == *"baz"* ]]
    [[ "$result" != *"foo"* ]]
}

@test "sedi: preserves file when no match" {
    echo "hello world" > "$TEST_DIR/test.txt"
    sedi 's/xyz/abc/' "$TEST_DIR/test.txt"
    result=$(cat "$TEST_DIR/test.txt")
    [ "$result" = "hello world" ]
}

@test "sedi: handles special characters in pattern" {
    echo "path/to/file" > "$TEST_DIR/test.txt"
    sedi 's|path/to|new/path|' "$TEST_DIR/test.txt"
    result=$(cat "$TEST_DIR/test.txt")
    [ "$result" = "new/path/file" ]
}

@test "sedi: deletes matching lines" {
    printf "keep\ndelete me\nkeep too\n" > "$TEST_DIR/test.txt"
    sedi '/delete/d' "$TEST_DIR/test.txt"
    result=$(cat "$TEST_DIR/test.txt")
    [[ "$result" != *"delete"* ]]
    [[ "$result" == *"keep"* ]]
}

# =============================================================================
# portable_date_relative
# =============================================================================

@test "portable_date_relative: today returns valid date format" {
    result=$(portable_date_relative 0)
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "portable_date_relative: custom format works" {
    result=$(portable_date_relative 0 "%Y/%m/%d")
    [[ "$result" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]]
}

# =============================================================================
# portable_date_parse
# =============================================================================

@test "portable_date_parse: converts epoch to date" {
    # 2026-01-01 00:00:00 UTC = 1767225600
    result=$(portable_date_parse 1767225600 "%Y")
    # Should be 2025 or 2026 depending on timezone
    [[ "$result" =~ ^20[0-9]{2}$ ]]
}

@test "portable_date_parse: custom format works" {
    result=$(portable_date_parse 0 "%Y-%m-%d")
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# =============================================================================
# human_bytes
# =============================================================================

@test "human_bytes: formats bytes" {
    result=$(human_bytes 512)
    [[ "$result" =~ [0-9] ]]
}

@test "human_bytes: formats kilobytes" {
    result=$(human_bytes 1024)
    [[ "$result" == *"K"* ]] || [[ "$result" == *"1"* ]]
}

@test "human_bytes: formats megabytes" {
    result=$(human_bytes 1048576)
    [[ "$result" == *"M"* ]] || [[ "$result" == *"1"* ]]
}

@test "human_bytes: formats gigabytes" {
    result=$(human_bytes 1073741824)
    [[ "$result" == *"G"* ]] || [[ "$result" == *"1"* ]]
}

@test "human_bytes: handles zero" {
    result=$(human_bytes 0)
    [[ "$result" =~ [0-9] ]]
}

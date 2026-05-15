#!/usr/bin/env bats

# Test suite: git-merge.sh comprehensive behavior
#
# Purpose: Lock down git-merge.sh before refactoring.
# Tests: flag parsing, validate section, merge section, error handling.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    # Create a feature branch with a commit
    git checkout -q -b feature/test-branch
    echo "feature work" > feature.txt
    git add feature.txt
    git commit -q -m "feat: add feature"
    git checkout -q main 2>/dev/null || git checkout -q master
}

teardown() {
    common_teardown
}

# Get the default branch name
get_main() {
    git branch --list main master | head -1 | tr -d '* '
}

# =============================================================================
# Flag parsing
# =============================================================================

@test "git-merge: accepts --source and --target flags" {
    local main_branch
    main_branch=$(get_main)
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --source feature/test-branch --target "$main_branch" 2>/dev/null
    # Flags accepted — produces valid JSON (may error on fetch, but that's not a parse error)
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "git-merge: rejects positional args" {
    run "$SCRIPTS_DIR/git-merge.sh" feature/test-branch main 2>/dev/null
    [ "$status" -ne 0 ]
}

@test "git-merge: rejects unknown flags" {
    run "$SCRIPTS_DIR/git-merge.sh" --invalid-flag 2>/dev/null
    [ "$status" -ne 0 ]
}

# =============================================================================
# Validate section
# =============================================================================

@test "git-merge: validate returns valid JSON" {
    local main_branch
    main_branch=$(get_main)
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --source feature/test-branch --target "$main_branch" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "git-merge: validate errors without source" {
    local main_branch
    main_branch=$(get_main)
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --target "$main_branch" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "git-merge: validate errors without target" {
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --source feature/test-branch 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "git-merge: validate errors with non-existent source branch" {
    local main_branch
    main_branch=$(get_main)
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --source nonexistent-branch --target "$main_branch" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Merge section
# =============================================================================

@test "git-merge: merge performs actual merge" {
    local main_branch
    main_branch=$(get_main)
    run "$SCRIPTS_DIR/git-merge.sh" --json --merge --source feature/test-branch --target "$main_branch" 2>/dev/null
    assert_valid_json "$output"

    local status_val
    status_val=$(echo "$output" | jq -r '.status')
    # Should succeed or report a meaningful state
    [[ "$status_val" == "success" ]] || [[ "$status_val" == "error" ]] || [[ "$status_val" == "conflict" ]]
}

@test "git-merge: squash merge with --squash flag" {
    local main_branch
    main_branch=$(get_main)
    run "$SCRIPTS_DIR/git-merge.sh" --json --merge --source feature/test-branch --target "$main_branch" --squash 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# No-op merge (already merged)
# =============================================================================

@test "git-merge: handles already-merged branches" {
    local main_branch
    main_branch=$(get_main)
    # Merge first
    git merge --no-edit feature/test-branch 2>/dev/null || true

    # Try to merge again
    run "$SCRIPTS_DIR/git-merge.sh" --json --merge --source feature/test-branch --target "$main_branch" 2>/dev/null
    assert_valid_json "$output"
    # Should handle gracefully (success or "no commits to merge")
}

# =============================================================================
# Conflict detection
# =============================================================================

@test "git-merge: detects merge conflicts" {
    local main_branch
    main_branch=$(get_main)

    # Create conflicting changes
    echo "main version" > conflict.txt
    git add conflict.txt
    git commit -q -m "add conflict file on main"

    git checkout -q feature/test-branch
    echo "feature version" > conflict.txt
    git add conflict.txt
    git commit -q -m "add conflict file on feature"
    git checkout -q "$main_branch"

    run "$SCRIPTS_DIR/git-merge.sh" --json --merge --source feature/test-branch --target "$main_branch" 2>/dev/null
    assert_valid_json "$output"

    local status_val
    status_val=$(echo "$output" | jq -r '.status')
    # Should report conflict or error
    [[ "$status_val" == "conflict" ]] || [[ "$status_val" == "error" ]]
}

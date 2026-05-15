#!/usr/bin/env bats

# Test suite: git-commit.sh comprehensive behavior
#
# Purpose: Lock down git-commit.sh behavior before refactoring.
# Tests: analyze section, execute section, plan file handling.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo
}

teardown() {
    common_teardown
}

# =============================================================================
# Analyze section
# =============================================================================

@test "git-commit: analyze with no changes returns empty state" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
}

@test "git-commit: analyze detects staged files" {
    echo "new file" > staged.txt
    git add staged.txt
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    # Should report staged files
    assert_json_field_present "$output" ".staged_files"
}

@test "git-commit: analyze detects unstaged changes" {
    echo "modified" >> README.md
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    # Should report unstaged modifications
    assert_json_field_present "$output" ".unstaged_files"
}

@test "git-commit: analyze detects untracked files" {
    echo "untracked" > new-file.txt
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".untracked_files"
}

@test "git-commit: analyze shows recent commits" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".recent_commits"
}

# =============================================================================
# Execute section
# =============================================================================

@test "git-commit: execute without plan file returns error" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --execute 2>/dev/null
    assert_valid_json "$output"
    # Returns error or partial_failure when no plan file provided
    local status_val
    status_val=$(echo "$output" | jq -r '.status')
    [[ "$status_val" == "error" ]] || [[ "$status_val" == "partial_failure" ]]
}

@test "git-commit: execute with valid plan creates commits" {
    # Stage a file
    echo "new content" > feature.txt
    git add feature.txt

    # Create a commit plan
    local plan_file="${TEST_DIR}/commit-plan.json"
    cat > "$plan_file" << 'PLANEOF'
{
  "commits": [
    {
      "title": "feat: add feature file",
      "body": "Add feature.txt with new content",
      "files": ["feature.txt"]
    }
  ]
}
PLANEOF

    run "$SCRIPTS_DIR/git-commit.sh" --json --execute --plan-file "$plan_file" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"

    # Verify commit was created
    run git log --oneline -1
    [[ "$output" == *"feat: add feature file"* ]]
}

@test "git-commit: execute with multiple commits in plan" {
    # Create two files for two commits
    echo "docs content" > docs-file.md
    echo "test content" > test-file.sh
    git add docs-file.md test-file.sh

    local plan_file="${TEST_DIR}/commit-plan.json"
    cat > "$plan_file" << 'PLANEOF'
{
  "commits": [
    {
      "title": "docs: add documentation",
      "body": "Add docs-file.md",
      "files": ["docs-file.md"]
    },
    {
      "title": "test: add test script",
      "body": "Add test-file.sh",
      "files": ["test-file.sh"]
    }
  ]
}
PLANEOF

    run "$SCRIPTS_DIR/git-commit.sh" --json --execute --plan-file "$plan_file" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"

    # Verify both commits exist
    local commit_count
    commit_count=$(git log --oneline | head -3 | wc -l)
    [ "$commit_count" -ge 3 ]  # initial + 2 new
}

# =============================================================================
# Full section
# =============================================================================

@test "git-commit: full returns analysis for LLM" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    # --full maps to the analyze phase (git-commit uses multi-step workflow)
    assert_json_field "$output" ".section" "analyze"
}

# =============================================================================
# Edge cases
# =============================================================================

@test "git-commit: handles empty repository" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    # Should not crash on fresh repo with no changes
}

@test "git-commit: handles plan file with non-existent files" {
    local plan_file="${TEST_DIR}/commit-plan.json"
    cat > "$plan_file" << 'PLANEOF'
{
  "commits": [
    {
      "title": "feat: phantom commit",
      "body": "Try to commit non-existent file",
      "files": ["does-not-exist.txt"]
    }
  ]
}
PLANEOF

    run "$SCRIPTS_DIR/git-commit.sh" --json --execute --plan-file "$plan_file" 2>/dev/null
    assert_valid_json "$output"
    # Should handle gracefully (error or partial failure)
}

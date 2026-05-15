#!/usr/bin/env bats

# Test suite: Argument parsing contract across all scripts
#
# Purpose: Lock down flag behavior BEFORE extracting to shared arg-parser.
# Every smart script must:
#   1. Accept --json and --raw output mode flags
#   2. Accept section flags (--full, --identify, etc.)
#   3. Reject unknown flags with exit code 2
#   4. Accept --task-id for task scripts (not positional args)
#   5. Default to --json --full when no flags given (where applicable)
#
# This prevents regressions when we extract common arg parsing.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo
}

teardown() {
    common_teardown
}

# =============================================================================
# Unknown flag rejection (exit code 2)
# =============================================================================

@test "args: task-start rejects unknown flag" {
    run "$SCRIPTS_DIR/task-start.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-continue rejects unknown flag" {
    run "$SCRIPTS_DIR/task-continue.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-close rejects unknown flag" {
    run "$SCRIPTS_DIR/task-close.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-hold rejects unknown flag" {
    run "$SCRIPTS_DIR/task-hold.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-audit rejects unknown flag" {
    run "$SCRIPTS_DIR/task-audit.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-code-review rejects unknown flag" {
    run "$SCRIPTS_DIR/task-code-review.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-summary rejects unknown flag" {
    run "$SCRIPTS_DIR/task-summary.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-plan rejects unknown flag" {
    run "$SCRIPTS_DIR/task-plan.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: add-dependency rejects unknown flag" {
    run "$SCRIPTS_DIR/add-dependency.sh" --bogus 2>/dev/null
    [ "$status" -ne 0 ]
}

@test "args: review-implement rejects unknown flag" {
    run "$SCRIPTS_DIR/review-implement.sh" --bogus 2>/dev/null
    [ "$status" -ne 0 ]
}

@test "args: git-merge rejects unknown flag" {
    run "$SCRIPTS_DIR/git-merge.sh" --bogus 2>/dev/null
    [ "$status" -ne 0 ]
}


# =============================================================================
# Positional arg rejection (no bare args allowed)
# =============================================================================

@test "args: task-start rejects positional args" {
    run "$SCRIPTS_DIR/task-start.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-continue rejects positional args" {
    run "$SCRIPTS_DIR/task-continue.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-close rejects positional args" {
    run "$SCRIPTS_DIR/task-close.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-hold rejects positional args" {
    run "$SCRIPTS_DIR/task-hold.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-audit rejects positional args" {
    run "$SCRIPTS_DIR/task-audit.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-code-review rejects positional args" {
    run "$SCRIPTS_DIR/task-code-review.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-summary rejects positional args" {
    run "$SCRIPTS_DIR/task-summary.sh" A3F2B9 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: task-plan rejects positional args" {
    run "$SCRIPTS_DIR/task-plan.sh" somefile.md 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: add-dependency rejects positional args" {
    run "$SCRIPTS_DIR/add-dependency.sh" flask 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "args: review-implement rejects positional args" {
    run "$SCRIPTS_DIR/review-implement.sh" somefile.md 2>/dev/null
    [ "$status" -ne 0 ]
}

@test "args: git-merge rejects positional args" {
    run "$SCRIPTS_DIR/git-merge.sh" main dev 2>/dev/null
    [ "$status" -ne 0 ]
}


# =============================================================================
# --json flag produces valid JSON
# =============================================================================

@test "args: task-start --json produces JSON output" {
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "args: task-continue --json produces JSON output" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
}

@test "args: task-close --json produces JSON output" {
    run "$SCRIPTS_DIR/task-close.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
}

@test "args: task-hold --json produces JSON output" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "args: task-audit --json produces JSON output" {
    run "$SCRIPTS_DIR/task-audit.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "args: git-commit --json --analyze produces JSON output" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
}

@test "args: plan-progress --json produces JSON output" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# --task-id flag acceptance
# =============================================================================

@test "args: task-start accepts --task-id" {
    run "$SCRIPTS_DIR/task-start.sh" --json --full --task-id A3F2B9 2>/dev/null
    # Should not fail with "Unknown option"
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --task-id" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-close accepts --task-id" {
    run "$SCRIPTS_DIR/task-close.sh" --json --identify --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-hold accepts --task-id" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --full --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-audit accepts --task-id" {
    run "$SCRIPTS_DIR/task-audit.sh" --json --full --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-code-review accepts --task-id" {
    run "$SCRIPTS_DIR/task-code-review.sh" --json --full --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-summary accepts --task-id" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --full --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}


# =============================================================================
# Section flag acceptance
# =============================================================================

@test "args: task-start accepts --identify section" {
    run "$SCRIPTS_DIR/task-start.sh" --json --identify --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-start accepts --verify section" {
    run "$SCRIPTS_DIR/task-start.sh" --json --verify --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-start accepts --create-branch section" {
    run "$SCRIPTS_DIR/task-start.sh" --json --create-branch --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-start accepts --setup-env section" {
    run "$SCRIPTS_DIR/task-start.sh" --json --setup-env --task-id A3F2B9 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --identify section" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --verify-branch section" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --verify-branch 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --run-tests section" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --run-tests 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --gather section" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --gather 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --commit section" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --commit 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-close accepts --identify section" {
    run "$SCRIPTS_DIR/task-close.sh" --json --identify 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-close accepts --complete section" {
    run "$SCRIPTS_DIR/task-close.sh" --json --complete 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-close accepts --cleanup section" {
    run "$SCRIPTS_DIR/task-close.sh" --json --cleanup 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: git-commit accepts --analyze section" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: git-commit accepts --execute section" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --execute 2>/dev/null
    [[ "$status" -ne 2 ]]
}

# =============================================================================
# task-continue pass-through flags
# =============================================================================

@test "args: task-continue accepts --completed-tasks" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --completed-tasks "1.1,1.2" 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --lessons" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --lessons "learned something" 2>/dev/null
    [[ "$status" -ne 2 ]]
}

@test "args: task-continue accepts --progress-note" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --progress-note "did work" 2>/dev/null
    [[ "$status" -ne 2 ]]
}

# =============================================================================
# git-merge named flags
# =============================================================================

@test "args: git-merge accepts --source and --target" {
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --source main --target main 2>/dev/null
    assert_valid_json "$output"
    # Should not fail with "Unknown option" — may fail with branch validation but that's fine
    local msg
    msg=$(echo "$output" | jq -r '.message // ""')
    [[ "$msg" != *"Unknown option"* ]]
}

@test "args: git-merge accepts --squash flag" {
    run "$SCRIPTS_DIR/git-merge.sh" --json --validate --source main --target main --squash 2>/dev/null
    assert_valid_json "$output"
    local msg
    msg=$(echo "$output" | jq -r '.message // ""')
    [[ "$msg" != *"Unknown option"* ]]
}

# =============================================================================
# task-plan named flags
# =============================================================================

@test "args: task-plan accepts --source" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --full --source "some-file.md" 2>/dev/null
    [[ "$status" -ne 2 ]]
}

# =============================================================================
# add-dependency named flags
# =============================================================================

@test "args: add-dependency accepts --package" {
    run "$SCRIPTS_DIR/add-dependency.sh" --json --full --package "flask" 2>/dev/null
    [[ "$status" -ne 2 ]]
}

# =============================================================================
# review-implement named flags
# =============================================================================

@test "args: review-implement accepts --document" {
    run "$SCRIPTS_DIR/review-implement.sh" --json --full --document "some-doc.md" 2>/dev/null
    [[ "$status" -ne 2 ]]
}

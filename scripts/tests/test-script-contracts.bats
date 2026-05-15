#!/usr/bin/env bats

# Test suite: Script contract verification
#
# Purpose: Verify that ALL smart scripts follow the expected contract.
# This is the broadest test — it checks every script that sources common.sh
# or doc-utils.sh for basic structural compliance.
#
# Tests:
#   1. All scripts pass bash syntax check
#   2. Scripts that define exit_with_json include required fields
#   3. Scripts source their dependencies correctly
#   4. No script uses positional args in its *) case
#   5. All scripts with --json flag produce valid JSON

load test_helper

setup() {
    common_setup
    SCRIPTS_DIR="${BATS_TEST_DIRNAME}/.."
}

teardown() {
    common_teardown
}

# =============================================================================
# Syntax validation
# =============================================================================

@test "contract: core scripts pass bash -n syntax check" {
    local core_scripts=(
        task-start.sh task-continue.sh task-close.sh task-hold.sh
        task-audit.sh task-code-review.sh task-summary.sh
        task-fetch.sh task-risk.sh task-resume.sh
        feature-review.sh
        git-commit.sh git-merge.sh
        task-plan.sh plan-progress.sh
        add-dependency.sh review-implement.sh
        common.sh doc-utils.sh
    )
    local failed=0
    local failed_files=""
    for script in "${core_scripts[@]}"; do
        if ! bash -n "$SCRIPTS_DIR/$script" 2>/dev/null; then
            failed=$((failed + 1))
            failed_files="$failed_files $script"
        fi
    done
    if [ "$failed" -gt 0 ]; then
        echo "Syntax errors in: $failed_files" >&2
        return 1
    fi
}

# =============================================================================
# No positional args in smart scripts
# =============================================================================

@test "contract: task-start.sh rejects bare args in *) case" {
    # Verify the *) case exits with error, not captures positional
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/task-start.sh" | grep -v '^\s*\*)' | head -1)
    # Should contain "echo" + "exit" or "Unknown", not variable assignment
    [[ "$catch_all" != *'INPUT="$1"'* ]]
    [[ "$catch_all" != *'SOURCE="$1"'* ]]
}

@test "contract: task-continue.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/task-continue.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: task-close.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/task-close.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'INPUT_ARG="$1"'* ]]
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: task-plan.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/task-plan.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'SOURCE="$1"'* ]]
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: add-dependency.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/add-dependency.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'PACKAGE="$1"'* ]]
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: git-merge.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/git-merge.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: task-summary.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/task-summary.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: task-code-review.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/task-code-review.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'="$1"'* ]]
}

@test "contract: review-implement.sh rejects bare args in *) case" {
    local catch_all
    catch_all=$(grep -A1 '^\s*\*)' "$SCRIPTS_DIR/review-implement.sh" | grep -v '^\s*\*)' | head -1)
    [[ "$catch_all" != *'="$1"'* ]]
}

# =============================================================================
# exit_with_json function signature consistency
# =============================================================================

@test "contract: exit_with_json takes status as first arg in task-start" {
    grep -q 'exit_with_json.*"error"' "$SCRIPTS_DIR/task-start.sh"
    grep -q 'exit_with_json.*"success"' "$SCRIPTS_DIR/task-start.sh"
}

@test "contract: exit_with_json takes status as first arg in task-continue" {
    grep -q 'exit_with_json.*"error"' "$SCRIPTS_DIR/task-continue.sh"
    grep -q 'exit_with_json.*"success"' "$SCRIPTS_DIR/task-continue.sh"
}

@test "contract: exit_with_json takes status as first arg in task-close" {
    grep -q 'exit_with_json.*"error"' "$SCRIPTS_DIR/task-close.sh"
    # task-close may use exit_with_json "success" or log_json for success
    grep -q 'exit_with_json\|log_json' "$SCRIPTS_DIR/task-close.sh"
}

@test "contract: exit_with_json takes status as first arg in git-commit" {
    grep -q 'exit_with_json.*"error"' "$SCRIPTS_DIR/git-commit.sh"
    # git-commit may use exit_with_json "success" or log_json for success
    grep -q 'exit_with_json\|log_json' "$SCRIPTS_DIR/git-commit.sh"
}

# =============================================================================
# Source dependencies present
# =============================================================================

@test "contract: task scripts source doc-utils.sh" {
    local scripts=(task-start.sh task-continue.sh task-close.sh task-hold.sh)
    for script in "${scripts[@]}"; do
        if ! grep -q 'source.*doc-utils.sh' "$SCRIPTS_DIR/$script"; then
            echo "$script does not source doc-utils.sh" >&2
            return 1
        fi
    done
}

@test "contract: common.sh is standalone (no circular deps)" {
    # common.sh should not source doc-utils.sh
    ! grep -q 'source.*doc-utils.sh' "$SCRIPTS_DIR/common.sh"
}

@test "contract: doc-utils.sh sources common.sh for shared functions" {
    # doc-utils.sh may source common.sh - verify it does so correctly
    if grep -q 'source.*common.sh' "$SCRIPTS_DIR/doc-utils.sh"; then
        # If it sources common.sh, verify it's using the right path
        grep -q 'SCRIPT_DIR\|BASH_SOURCE\|dirname' "$SCRIPTS_DIR/doc-utils.sh"
    fi
    true  # Either way is acceptable
}

# =============================================================================
# OUTPUT_MODE default
# =============================================================================

@test "contract: smart scripts default OUTPUT_MODE to json" {
    local scripts=(task-start.sh task-continue.sh task-close.sh task-hold.sh
                   git-commit.sh task-audit.sh task-code-review.sh)
    for script in "${scripts[@]}"; do
        if grep -q 'OUTPUT_MODE=' "$SCRIPTS_DIR/$script"; then
            local default
            default=$(grep 'OUTPUT_MODE=' "$SCRIPTS_DIR/$script" | head -1)
            if [[ "$default" == *'"raw"'* ]] && [[ "$default" != *'--raw'* ]]; then
                echo "$script defaults to raw instead of json" >&2
                return 1
            fi
        fi
    done
}

# =============================================================================
# SECTION default
# =============================================================================

@test "contract: smart scripts default SECTION to full" {
    # git-commit.sh is excluded — it uses a multi-step workflow (analyze → analyze-diffs → execute)
    # where the default is "analyze", not "full"
    local scripts=(task-start.sh task-continue.sh task-close.sh task-hold.sh)
    for script in "${scripts[@]}"; do
        if grep -q 'SECTION=' "$SCRIPTS_DIR/$script"; then
            local default
            default=$(grep 'SECTION="' "$SCRIPTS_DIR/$script" | head -1)
            if [[ "$default" != *'"full"'* ]]; then
                echo "$script does not default SECTION to full: $default" >&2
                return 1
            fi
        fi
    done
}

# =============================================================================
# set -euo pipefail
# =============================================================================

@test "contract: core scripts use set -euo pipefail" {
    local core_scripts=(
        task-start.sh task-continue.sh task-close.sh task-hold.sh
        task-code-review.sh task-fetch.sh task-risk.sh task-resume.sh
        feature-review.sh
        git-commit.sh git-merge.sh
        task-plan.sh add-dependency.sh review-implement.sh
    )
    local failed=""
    for script in "${core_scripts[@]}"; do
        if ! head -5 "$SCRIPTS_DIR/$script" | grep -q 'set -euo pipefail'; then
            failed="$failed $script"
        fi
    done
    if [ -n "$failed" ]; then
        echo "Missing 'set -euo pipefail':$failed" >&2
        return 1
    fi
}

# =============================================================================
# Shebang line
# =============================================================================

@test "contract: core scripts have proper shebang" {
    local core_scripts=(
        task-start.sh task-continue.sh task-close.sh task-hold.sh
        task-audit.sh task-code-review.sh task-summary.sh
        task-fetch.sh task-risk.sh task-resume.sh
        feature-review.sh
        git-commit.sh git-merge.sh
        task-plan.sh plan-progress.sh
        add-dependency.sh review-implement.sh
        common.sh doc-utils.sh
    )
    local failed=""
    for script in "${core_scripts[@]}"; do
        local first_line
        first_line=$(head -1 "$SCRIPTS_DIR/$script")
        if [[ "$first_line" != "#!/usr/bin/env bash" ]] && [[ "$first_line" != "#!/bin/bash" ]]; then
            failed="$failed $script"
        fi
    done
    if [ -n "$failed" ]; then
        echo "Bad or missing shebang:$failed" >&2
        return 1
    fi
}

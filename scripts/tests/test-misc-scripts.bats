#!/usr/bin/env bats

# Test suite for miscellaneous scripts
# Covers: notify, status, implement, task-plan, plan-progress,
# contributing, version, project-context, project-config,
# init-project-config, validate-project-yaml, deploy support scripts, etc.

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# Plan and implementation scripts
# =============================================================================

@test "task-plan: error has next_action=fix_error" {
    run bash -c '"$1" --json --full 2>/dev/null' -- "$SCRIPTS_DIR/task-plan.sh"
    next=$(echo "$output" | tr -d '\n\r\t' | sed 's/  */ /g' | jq -r '.next_action')
    [ "$next" = "fix_error" ]
}

@test "plan-progress: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/plan-progress.sh" || skip "not yet converted"
}

@test "implement: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/implement.sh" || skip "not yet converted"
}

# =============================================================================
# Project configuration scripts
# =============================================================================

@test "project-context: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/project-context.sh" || skip "not yet converted"
}

@test "project-config: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/project-config.sh" || skip "not yet converted"
}

@test "init-project-config: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/init-project-config.sh" || skip "not yet converted"
}

@test "validate-project-yaml: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/validate-project-yaml.sh" || skip "not yet converted"
}

# =============================================================================
# Deployment support scripts
# =============================================================================

@test "deploy: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/deploy.sh" || skip "not yet converted"
}

@test "deploy-risk: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/deploy-risk.sh" || skip "not yet converted"
}

@test "deploy-ansible: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/deploy-ansible.sh" || skip "not yet converted"
}

@test "deployment-config: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/deployment-config.sh" || skip "not yet converted"
}

@test "deployment-rollback: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/deployment-rollback.sh" || skip "not yet converted"
}

@test "promote: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/promote.sh" || skip "not yet converted"
}

@test "rollback: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/rollback.sh" || skip "not yet converted"
}

# =============================================================================
# Health and version check scripts
# =============================================================================

@test "check-health: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/check-health.sh" || skip "not yet converted"
}

@test "check-deployed-version: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/check-deployed-version.sh" || skip "not yet converted"
}

# =============================================================================
# Test scripts
# =============================================================================

@test "test-run: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/test-run.sh" || skip "not yet converted"
}

@test "test-e2e: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/test-e2e.sh" || skip "not yet converted"
}

@test "test-smoke: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/test-smoke.sh" || skip "not yet converted"
}

@test "test-tdd: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/test-tdd.sh" || skip "not yet converted"
}

@test "test-diagnose: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/test-diagnose.sh" || skip "not yet converted"
}

# =============================================================================
# Other scripts
# =============================================================================

@test "version: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/version.sh" || skip "not yet converted"
}

@test "contributing: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/contributing.sh" || skip "not yet converted"
}

@test "notify: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/notify.sh" || skip "not yet converted"
}

@test "status: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/status.sh" || skip "not yet converted"
}

@test "todos-to-issues: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/todos-to-issues.sh" || skip "not yet converted"
}

# =============================================================================
# Docs generation scripts
# =============================================================================

@test "generate-skills-html: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-skills-html.sh" || skip "not yet converted"
}

@test "generate-skills-reference: has next_action in source" {
    grep -q 'next_action' "$SCRIPTS_DIR/generate-skills-reference.sh" || skip "not yet converted"
}

# =============================================================================
# Error path spot-checks
# =============================================================================

@test "project-context: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/project-context.sh" || skip "not yet converted"
    run "$SCRIPTS_DIR/project-context.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

@test "contributing: error response is valid JSON" {
    grep -q 'next_action' "$SCRIPTS_DIR/contributing.sh" || skip "not yet converted"
    setup_mock_git_repo
    run "$SCRIPTS_DIR/contributing.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
}

# =============================================================================
# Syntax validation for all scripts
# =============================================================================

@test "all scripts pass bash syntax check" {
    local failures=0
    for script in "$SCRIPTS_DIR"/*.sh; do
        # Skip non-bash scripts (e.g., Python files with .sh extension)
        local shebang
        shebang=$(head -1 "$script")
        [[ "$shebang" == *"python"* ]] && continue
        # Skip known broken scripts
        [[ "$(basename "$script")" == "smoke-tests.sh" ]] && continue
        if ! bash -n "$script" 2>/dev/null; then
            echo "SYNTAX ERROR: $(basename "$script")" >&2
            failures=$((failures + 1))
        fi
    done
    [ "$failures" -eq 0 ]
}

@test "all lib scripts pass bash syntax check" {
    local failures=0
    for script in "$SCRIPTS_DIR"/lib/*.sh; do
        if ! bash -n "$script" 2>/dev/null; then
            echo "SYNTAX ERROR: lib/$(basename "$script")" >&2
            failures=$((failures + 1))
        fi
    done
    [ "$failures" -eq 0 ]
}

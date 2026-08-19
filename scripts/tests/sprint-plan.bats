#!/usr/bin/env bats
# Tests for scripts/sprint-plan.sh — guard rails only.
#
# The identify/inventory/apply paths past validation call the Asana API, so these
# cover the preconditions that must fail closed *before* any network or write
# happens: missing config, wrong backend, wrong branch, and a dry run that
# writes nothing. Capacity arithmetic and selection are covered by
# scripts/tests/test_sprint_select.py.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../sprint-plan.sh"
    [[ -f "$SCRIPT" ]] || skip "sprint-plan.sh not found"

    TMPDIR_TEST="$(mktemp -d)"
    TMPDIR_TEST="$(cd "$TMPDIR_TEST" && pwd -P)"
    git init "$TMPDIR_TEST/repo" --initial-branch=dev >/dev/null 2>&1
    cd "$TMPDIR_TEST/repo"
    git commit --allow-empty -m init >/dev/null 2>&1
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "$TMPDIR_TEST"
}

write_project_yaml() {
    cat >"$TMPDIR_TEST/repo/PROJECT.yaml" <<YAML
name: sprint-test
task_management:
  backend: ${1:-asana}
  asana:
    workspace_id: '1162186193001399'
    project_id: '${2:-1234567890}'
YAML
}

# ─── preconditions ───────────────────────────────────────────────────────────

@test "sprint-plan: missing PROJECT.yaml returns fix_error" {
    cd "$TMPDIR_TEST/repo"
    run "$SCRIPT" --json --identify
    [ "$status" -eq 1 ]
    [[ "$output" == *"fix_error"* ]]
    [[ "$output" == *"PROJECT.yaml"* ]]
}

@test "sprint-plan: non-asana backend returns fix_error" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml "gitlab"
    run "$SCRIPT" --json --identify
    [ "$status" -eq 1 ]
    [[ "$output" == *"asana backend"* ]]
}

@test "sprint-plan: off-dev branch is blocked before any API call" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    git checkout -q -b feature/ABC123-something
    run "$SCRIPT" --json --identify
    [ "$status" -eq 1 ]
    [[ "$output" == *"blocked"* ]]
    [[ "$output" == *"Not on dev"* ]]
}

@test "sprint-plan: blocked output names the branch to switch to" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    git checkout -q -b feature/ABC123-something
    run "$SCRIPT" --json --identify
    [[ "$output" == *"required_branch"* ]]
    [[ "$output" == *"checkout dev"* ]]
}

# ─── select ──────────────────────────────────────────────────────────────────

@test "sprint-plan: --select without --decisions returns fix_error" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    run "$SCRIPT" --json --select
    [ "$status" -eq 1 ]
    [[ "$output" == *"--decisions"* ]]
}

@test "sprint-plan: --select rejects a malformed decisions file" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    echo 'not json' >"$TMPDIR_TEST/bad.json"
    run "$SCRIPT" --json --select --decisions "$TMPDIR_TEST/bad.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "sprint-plan: --select computes a plan and writes a plan file" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    cat >"$TMPDIR_TEST/dec.json" <<'JSON'
{"candidates":[{"gid":"1","name":"a","points":3,"relevance":9}]}
JSON
    run "$SCRIPT" --json --select --decisions "$TMPDIR_TEST/dec.json" --sprint-label TEST-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready_for_sync"* ]]
    [[ "$output" == *"plan_file"* ]]
}

# ─── apply ───────────────────────────────────────────────────────────────────

@test "sprint-plan: --apply-plan without --plan returns fix_error" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    run "$SCRIPT" --json --apply-plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"--plan"* ]]
}

@test "sprint-plan: apply is a dry run unless --apply is passed" {
    cd "$TMPDIR_TEST/repo"
    write_project_yaml
    cat >"$TMPDIR_TEST/plan.json" <<'JSON'
{"actions":[{"action":"move_task","gid":"1","name":"a","section":"Current Sprint"}],
 "capacity":{"total_points":20}}
JSON
    run "$SCRIPT" --json --apply-plan --plan "$TMPDIR_TEST/plan.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry_run"* ]]
    [[ "$output" == *"nothing written"* ]]
}

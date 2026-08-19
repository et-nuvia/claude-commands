#!/usr/bin/env bats

# Test suite for common.sh utility functions
# Covers: normalize_task_id, map_next_action, json_escape, resolve_task_context, compute_task_id

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/common.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# normalize_task_id
# =============================================================================

@test "normalize_task_id: uppercase hex passes through" {
    result=$(normalize_task_id "A3F2B9")
    [ "$result" = "A3F2B9" ]
}

@test "normalize_task_id: lowercase hex normalizes to uppercase" {
    result=$(normalize_task_id "a3f2b9")
    [ "$result" = "A3F2B9" ]
}

@test "normalize_task_id: mixed case normalizes to uppercase" {
    result=$(normalize_task_id "a3F2b9")
    [ "$result" = "A3F2B9" ]
}

@test "normalize_task_id: rejects too short" {
    run normalize_task_id "A3F2B"
    [ "$status" -ne 0 ]
}

@test "normalize_task_id: rejects too long" {
    run normalize_task_id "A3F2B90"
    [ "$status" -ne 0 ]
}

@test "normalize_task_id: rejects non-hex characters" {
    run normalize_task_id "G3F2B9"
    [ "$status" -ne 0 ]
}

@test "normalize_task_id: rejects empty string" {
    run normalize_task_id ""
    [ "$status" -ne 0 ]
}

@test "normalize_task_id: all zeros is valid" {
    result=$(normalize_task_id "000000")
    [ "$result" = "000000" ]
}

@test "normalize_task_id: all F's is valid" {
    result=$(normalize_task_id "ffffff")
    [ "$result" = "FFFFFF" ]
}

# =============================================================================
# map_next_action
# =============================================================================

@test "map_next_action: success maps to display_summary" {
    result=$(map_next_action "success")
    [ "$result" = "display_summary" ]
}

@test "map_next_action: conflict maps to resolve_conflicts" {
    result=$(map_next_action "conflict")
    [ "$result" = "resolve_conflicts" ]
}

@test "map_next_action: needs_decision maps to confirm_action" {
    result=$(map_next_action "needs_decision")
    [ "$result" = "confirm_action" ]
}

@test "map_next_action: ready_for_sync maps to sync_asana" {
    result=$(map_next_action "ready_for_sync")
    [ "$result" = "sync_asana" ]
}

@test "map_next_action: needs_llm maps to parse_content" {
    result=$(map_next_action "needs_llm")
    [ "$result" = "parse_content" ]
}

@test "map_next_action: ready_for_review maps to analyze_code" {
    result=$(map_next_action "ready_for_review")
    [ "$result" = "analyze_code" ]
}

@test "map_next_action: unknown status defaults to fix_error" {
    result=$(map_next_action "anything_else")
    [ "$result" = "fix_error" ]
}

@test "map_next_action: empty string defaults to fix_error" {
    result=$(map_next_action "")
    [ "$result" = "fix_error" ]
}

# =============================================================================
# json_escape
# =============================================================================

@test "json_escape: simple string" {
    result=$(json_escape "hello world")
    [ "$result" = '"hello world"' ]
}

@test "json_escape: string with quotes" {
    result=$(json_escape 'hello "world"')
    [ "$result" = '"hello \"world\""' ]
}

@test "json_escape: empty string" {
    result=$(json_escape "")
    [ "$result" = '""' ]
}

@test "json_escape: string with backslash" {
    result=$(json_escape 'path\to\file')
    [ "$result" = '"path\\to\\file"' ]
}

# =============================================================================
# compute_task_id
# =============================================================================

@test "compute_task_id: produces 6-char uppercase hex" {
    result=$(compute_task_id "2602140922" "convert-commands")
    [[ "$result" =~ ^[A-F0-9]{6}$ ]]
}

@test "compute_task_id: deterministic output" {
    result1=$(compute_task_id "2602140922" "my-task")
    result2=$(compute_task_id "2602140922" "my-task")
    [ "$result1" = "$result2" ]
}

@test "compute_task_id: different inputs produce different IDs" {
    result1=$(compute_task_id "2602140922" "task-one")
    result2=$(compute_task_id "2602140923" "task-two")
    [ "$result1" != "$result2" ]
}

# =============================================================================
# compute_year_month
# =============================================================================

@test "compute_year_month: extracts year-month from YYMMDDHHMM" {
    result=$(compute_year_month "2602140922")
    [ "$result" = "2026-02" ]
}

@test "compute_year_month: handles December" {
    result=$(compute_year_month "2512010800")
    [ "$result" = "2025-12" ]
}

@test "compute_year_month: handles January" {
    result=$(compute_year_month "2601150900")
    [ "$result" = "2026-01" ]
}

# =============================================================================
# resolve_task_context
# =============================================================================

# =============================================================================
# load_current_task (JSON format)
# =============================================================================

@test "load_current_task: returns 1 when file missing" {
    run load_current_task
    [ "$status" -eq 1 ]
    # CT_TASK_ID is set inside `run`'s subshell; under set -u it would
    # also be unbound in our shell. Either way "no task loaded" means
    # the var was never assigned a non-empty value.
    [ -z "${CT_TASK_ID:-}" ]
}

@test "load_current_task: parses JSON with all core fields" {
    cat > .current-task <<'JSON'
{
  "task_id": "A3F2B9",
  "branch": "feature/A3F2B9-my-task",
  "parent_branch": "main",
  "task_doc": "docs/active/2026-03/A3F2B9-TSK-desc.md",
  "started": "2026-03-17T02:18:00Z",
  "task_tracker": null
}
JSON
    load_current_task
    [ "$CT_TASK_ID" = "A3F2B9" ]
    [ "$CT_BRANCH" = "feature/A3F2B9-my-task" ]
    [ "$CT_PARENT_BRANCH" = "main" ]
    [ "$CT_TASK_DOC" = "docs/active/2026-03/A3F2B9-TSK-desc.md" ]
    [ "$CT_STARTED" = "2026-03-17T02:18:00Z" ]
}

@test "load_current_task: parses JSON with task_tracker object" {
    cat > .current-task <<'JSON'
{
  "task_id": "B4C5D6",
  "branch": "feature/B4C5D6-asana-task",
  "parent_branch": "dev",
  "task_doc": "docs/active/2026-03/B4C5D6-TSK-desc.md",
  "started": "2026-03-17T02:18:00Z",
  "task_tracker": {
    "backend": "asana",
    "id": "1234567890123456",
    "url": "https://app.asana.com/0/0/1234567890123456"
  }
}
JSON
    load_current_task
    [ "$CT_TRACKER_BACKEND" = "asana" ]
    [ "$CT_TRACKER_ID" = "1234567890123456" ]
    [ "$CT_TRACKER_URL" = "https://app.asana.com/0/0/1234567890123456" ]
    # CT_ASANA_GID alias when backend is asana
    [ "$CT_ASANA_GID" = "1234567890123456" ]
}

@test "load_current_task: CT_ASANA_GID empty when tracker is not asana" {
    cat > .current-task <<'JSON'
{
  "task_id": "C5D6E7",
  "branch": "feature/C5D6E7-gitlab-task",
  "parent_branch": "main",
  "task_doc": "docs/active/2026-03/C5D6E7-TSK-desc.md",
  "started": "2026-03-17T02:18:00Z",
  "task_tracker": {
    "backend": "gitlab",
    "id": "42",
    "url": "https://git.example.com/group/project/-/issues/42"
  }
}
JSON
    load_current_task
    [ "$CT_TRACKER_BACKEND" = "gitlab" ]
    [ "$CT_TRACKER_ID" = "42" ]
    [ -z "$CT_ASANA_GID" ]
}

@test "load_current_task: null task_tracker sets empty tracker fields" {
    cat > .current-task <<'JSON'
{
  "task_id": "D6E7F8",
  "branch": "feature/D6E7F8-no-tracker",
  "parent_branch": "main",
  "task_doc": "docs/active/2026-03/D6E7F8-TSK-desc.md",
  "started": "2026-03-17T02:18:00Z",
  "task_tracker": null
}
JSON
    load_current_task
    [ -z "$CT_TRACKER_BACKEND" ]
    [ -z "$CT_TRACKER_ID" ]
    [ -z "$CT_TRACKER_URL" ]
    [ -z "$CT_ASANA_GID" ]
}

@test "load_current_task: normalizes lowercase task_id to uppercase" {
    cat > .current-task <<'JSON'
{"task_id": "a3f2b9", "branch": "x", "parent_branch": "main", "task_doc": "x", "started": "x", "task_tracker": null}
JSON
    load_current_task
    [ "$CT_TASK_ID" = "A3F2B9" ]
}

@test "load_current_task: returns 1 for invalid JSON" {
    echo "not json" > .current-task
    run load_current_task
    [ "$status" -eq 1 ]
}

@test "load_current_task: returns 1 when task_id missing from JSON" {
    echo '{"branch": "x", "task_doc": "x"}' > .current-task
    run load_current_task
    [ "$status" -eq 1 ]
}

# =============================================================================
# write_current_task
# =============================================================================

@test "write_current_task: produces valid JSON" {
    write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "" ""
    [ -f ".current-task" ]
    jq . .current-task >/dev/null 2>&1
}

@test "write_current_task: sets all core fields" {
    write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "" ""
    [ "$(jq -r '.task_id' .current-task)" = "A3F2B9" ]
    [ "$(jq -r '.branch' .current-task)" = "feature/A3F2B9-task" ]
    [ "$(jq -r '.parent_branch' .current-task)" = "main" ]
    [ "$(jq -r '.task_doc' .current-task)" = "docs/TSK.md" ]
    [ "$(jq -r '.started' .current-task)" != "null" ]
    [ "$(jq -r '.task_tracker' .current-task)" = "null" ]
}

@test "write_current_task: sets task_tracker for asana" {
    write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "asana" "1234567890"
    [ "$(jq -r '.task_tracker.backend' .current-task)" = "asana" ]
    [ "$(jq -r '.task_tracker.id' .current-task)" = "1234567890" ]
    [ "$(jq -r '.task_tracker.url' .current-task)" = "https://app.asana.com/0/0/1234567890" ]
}

@test "write_current_task: sets task_tracker for gitlab" {
    # Need PROJECT.yaml for gitlab URL generation
    cat > PROJECT.yaml <<'YAML'
git:
  platform: gitlab
  instance: git.example.com
  repo: docker/mcps
YAML
    write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "gitlab" "42"
    [ "$(jq -r '.task_tracker.backend' .current-task)" = "gitlab" ]
    [ "$(jq -r '.task_tracker.id' .current-task)" = "42" ]
    [ "$(jq -r '.task_tracker.url' .current-task)" = "https://git.example.com/docker/mcps/-/issues/42" ]
}

@test "write_current_task: sets task_tracker for github" {
    cat > PROJECT.yaml <<'YAML'
git:
  platform: github
  repo: owner/repo
YAML
    write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "github" "99"
    [ "$(jq -r '.task_tracker.backend' .current-task)" = "github" ]
    [ "$(jq -r '.task_tracker.id' .current-task)" = "99" ]
    [ "$(jq -r '.task_tracker.url' .current-task)" = "https://github.com/owner/repo/issues/99" ]
}

@test "write_current_task: null tracker when no backend provided" {
    write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "" ""
    [ "$(jq -r '.task_tracker' .current-task)" = "null" ]
}

# =============================================================================
# resolve_task_context
# =============================================================================

@test "resolve_task_context: explicit ID passed through" {
    setup_mock_git_repo
    result=$(resolve_task_context "a3f2b9")
    [ "$result" = "A3F2B9" ]
}

@test "resolve_task_context: reads from .current-task file" {
    setup_mock_git_repo
    echo '{"task_id":"A3F2B9","branch":"x","parent_branch":"main","task_doc":"x","started":"x","task_tracker":null}' > .current-task
    result=$(resolve_task_context)
    [ "$result" = "A3F2B9" ]
}

@test "resolve_task_context: extracts from branch name" {
    setup_mock_git_repo
    git checkout -q -b "feature/A3F2B9-my-task"
    result=$(resolve_task_context)
    [ "$result" = "A3F2B9" ]
}

@test "resolve_task_context: mismatch returns JSON with both IDs" {
    setup_mock_git_repo
    git checkout -q -b "feature/A3F2B9-my-task"
    echo '{"task_id":"BBBBBB","branch":"x","parent_branch":"main","task_doc":"x","started":"x","task_tracker":null}' > .current-task
    run resolve_task_context
    [ "$status" -ne 0 ]
    assert_json_field "$output" ".status" "mismatch"
    assert_json_field_present "$output" ".current_task_id"
    assert_json_field_present "$output" ".branch_task_id"
}

@test "resolve_task_context: no context returns not_found JSON" {
    setup_mock_git_repo
    run resolve_task_context
    [ "$status" -ne 0 ]
    assert_json_field "$output" ".status" "not_found"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "resolve_task_context: invalid explicit ID returns error" {
    run resolve_task_context "invalid"
    [ "$status" -ne 0 ]
}

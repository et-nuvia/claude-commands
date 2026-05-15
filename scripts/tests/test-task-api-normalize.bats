#!/usr/bin/env bats
# Functional tests for the task adapter normalize logic. Each test
# overrides the adapter's low-level call function with a stub that
# returns canned JSON, then verifies the high-level task_* function
# produces the expected normalized output.
#
# This catches bugs that the grep-based contract test can't — e.g.,
# task_hold not actually marking held, status normalization
# misclassifying inputs, etc.

setup() {
  cd "${BATS_TEST_DIRNAME}/../.." || exit 1
}

# ----------------------------------------------------------------------
# gitlab-tasks
# ----------------------------------------------------------------------

@test "gitlab-tasks: normalize maps state=closed → status=closed" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=gitlab-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    # Stub the project_id and HTTP call
    _gitlab_tasks_project_id() { echo "owner%2Frepo"; }
    _gitlab_tasks_call() {
      echo "{\"iid\":42,\"title\":\"T\",\"state\":\"closed\",\"labels\":[],\"assignee\":null,\"created_at\":\"t\",\"updated_at\":\"t\",\"web_url\":\"u\"}"
    }
    task_get 42 | jq -r .status
  '
  [ "$status" -eq 0 ]
  [ "$output" = "closed" ]
}

@test "gitlab-tasks: normalize maps on-hold label → status=on_hold" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=gitlab-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    _gitlab_tasks_project_id() { echo "owner%2Frepo"; }
    _gitlab_tasks_call() {
      echo "{\"iid\":42,\"title\":\"T\",\"state\":\"opened\",\"labels\":[\"on-hold\"],\"assignee\":null,\"created_at\":\"t\",\"updated_at\":\"t\",\"web_url\":\"u\"}"
    }
    task_get 42 | jq -r .status
  '
  [ "$status" -eq 0 ]
  [ "$output" = "on_hold" ]
}

@test "gitlab-tasks: task_list returns normalized array" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=gitlab-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    _gitlab_tasks_project_id() { echo "owner%2Frepo"; }
    _gitlab_tasks_call() {
      echo "[{\"iid\":1,\"title\":\"a\",\"state\":\"opened\",\"labels\":[],\"assignee\":null,\"created_at\":\"t\",\"updated_at\":\"t\",\"web_url\":\"u\"},{\"iid\":2,\"title\":\"b\",\"state\":\"closed\",\"labels\":[],\"assignee\":null,\"created_at\":\"t\",\"updated_at\":\"t\",\"web_url\":\"u\"}]"
    }
    task_list | jq -r "map(.status) | join(\",\")"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "open,closed" ]
}

@test "gitlab-tasks: task_url is deterministic (no API call)" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=gitlab-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    _gitlab_tasks_project_id() { echo "owner%2Frepo"; }
    _GITLAB_TASKS_HOST="gitlab.example.com"
    # Fail if anyone tries to call the API
    _gitlab_tasks_call() { echo "API CALL MADE" >&2; return 1; }
    task_url 42
  '
  [ "$status" -eq 0 ]
  [ "$output" = "https://gitlab.example.com/owner/repo/-/issues/42" ]
}

# ----------------------------------------------------------------------
# github-tasks (only test the parts that do not require gh CLI)
# ----------------------------------------------------------------------

@test "github-tasks: task_url is deterministic (no API call)" {
  # Skip if gh CLI not installed — adapter won't even load
  if ! command -v gh >/dev/null 2>&1; then skip "gh CLI not installed"; fi
  run bash -c '
    TASK_ADAPTER_OVERRIDE=github-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    _GH_FULL_REPO_CACHED="owner/repo"  # bypass _github_tasks_full_repo
    task_url 42
  '
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/owner/repo/issues/42" ]
}

@test "github-tasks: normalize maps state=CLOSED → status=closed" {
  if ! command -v gh >/dev/null 2>&1; then skip "gh CLI not installed"; fi
  run bash -c '
    TASK_ADAPTER_OVERRIDE=github-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    _gh_tasks_get() {
      echo "{\"number\":42,\"title\":\"T\",\"state\":\"CLOSED\",\"labels\":[],\"assignees\":[],\"createdAt\":\"t\",\"updatedAt\":\"t\",\"url\":\"u\"}"
    }
    task_get 42 | jq -r .status
  '
  [ "$status" -eq 0 ]
  [ "$output" = "closed" ]
}

@test "github-tasks: normalize maps on-hold label → status=on_hold" {
  if ! command -v gh >/dev/null 2>&1; then skip "gh CLI not installed"; fi
  run bash -c '
    TASK_ADAPTER_OVERRIDE=github-tasks
    source scripts/lib/task-api.sh
    load_task_adapter
    _gh_tasks_get() {
      echo "{\"number\":42,\"title\":\"T\",\"state\":\"OPEN\",\"labels\":[{\"name\":\"on-hold\"}],\"assignees\":[],\"createdAt\":\"t\",\"updatedAt\":\"t\",\"url\":\"u\"}"
    }
    task_get 42 | jq -r .status
  '
  [ "$status" -eq 0 ]
  [ "$output" = "on_hold" ]
}

# ----------------------------------------------------------------------
# asana
# ----------------------------------------------------------------------

@test "asana: normalize maps completed:true → status=closed" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=asana
    source scripts/lib/task-api.sh
    load_task_adapter
    _asana_call() {
      echo "{\"data\":{\"gid\":\"42\",\"name\":\"T\",\"completed\":true,\"assignee\":null,\"memberships\":[],\"created_at\":\"t\",\"modified_at\":\"t\",\"permalink_url\":\"u\"}}"
    }
    task_get 42 | jq -r .status
  '
  [ "$status" -eq 0 ]
  [ "$output" = "closed" ]
}

@test "asana: normalize maps section name containing 'hold' → status=on_hold" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=asana
    source scripts/lib/task-api.sh
    load_task_adapter
    _asana_call() {
      echo "{\"data\":{\"gid\":\"42\",\"name\":\"T\",\"completed\":false,\"assignee\":null,\"memberships\":[{\"section\":{\"name\":\"On Hold\"}}],\"created_at\":\"t\",\"modified_at\":\"t\",\"permalink_url\":\"u\"}}"
    }
    task_get 42 | jq -r .status
  '
  [ "$status" -eq 0 ]
  [ "$output" = "on_hold" ]
}

@test "asana: task_hold moves task to hold section when one exists" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=asana
    source scripts/lib/task-api.sh
    load_task_adapter

    # Use a file for the call log so subshells (created by $(...)) can
    # accumulate into it. A variable would be lost across subshells.
    CALLLOG=$(mktemp)
    _asana_default_project() { echo "PROJ123"; }
    _asana_call() {
      local method="$1" endpoint="$2"
      echo "${method} ${endpoint}" >> "$CALLLOG"
      case "$endpoint" in
        */sections*)
          echo "{\"data\":[{\"gid\":\"SEC456\",\"name\":\"Hold\"}]}"
          ;;
        *)
          echo "{}"
          ;;
      esac
    }

    task_hold 42 "external review" "vendor"
    rc=$?
    echo "CALLS:"
    cat "$CALLLOG"
    rm -f "$CALLLOG"
    echo "rc=$rc"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST /tasks/42/stories"* ]]
  [[ "$output" == *"GET /projects/PROJ123/sections"* ]]
  [[ "$output" == *"POST /sections/SEC456/addTask"* ]]
  [[ "$output" == *"rc=0"* ]]
}

@test "asana: task_hold falls back to comment-only when no hold section" {
  run bash -c '
    TASK_ADAPTER_OVERRIDE=asana
    source scripts/lib/task-api.sh
    load_task_adapter

    CALLLOG=$(mktemp)
    _asana_default_project() { echo "PROJ123"; }
    _asana_call() {
      local method="$1" endpoint="$2"
      echo "${method} ${endpoint}" >> "$CALLLOG"
      case "$endpoint" in
        */sections*) echo "{\"data\":[{\"gid\":\"SEC1\",\"name\":\"Backlog\"}]}" ;;
        *) echo "{}" ;;
      esac
    }

    task_hold 42 "reason" "waiting" 2>/tmp/stderr
    rc=$?
    echo "CALLS:"
    cat "$CALLLOG"
    rm -f "$CALLLOG"
    echo "stderr:"
    cat /tmp/stderr
    rm -f /tmp/stderr
    echo "rc=$rc"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST /tasks/42/stories"* ]]
  [[ "$output" == *"GET /projects/PROJ123/sections"* ]]
  [[ "$output" != *"/sections/"*"/addTask"* ]]
  [[ "$output" == *"no section named"* ]]
  [[ "$output" == *"rc=0"* ]]
}

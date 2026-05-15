#!/usr/bin/env bats
# Contract test: every adapter in scripts/lib/task-backends/ MUST
# implement every function defined in the contract.

CONTRACT_FUNCTIONS=(
  task_get
  task_list
  task_search
  task_url
  task_health
  task_create
  task_update
  task_close
  task_hold
  task_resume
  task_comment
)

ADAPTERS_DIR="${BATS_TEST_DIRNAME}/../lib/task-backends"

setup() {
  cd "${BATS_TEST_DIRNAME}/../.." || exit 1
}

@test "dispatcher: load_task_adapter rejects unknown backend" {
  TASK_ADAPTER_OVERRIDE=__unknown__ run bash -c \
    'source scripts/lib/task-api.sh; load_task_adapter'
  [ "$status" -ne 0 ]
}

@test "dispatcher: load_task_adapter accepts none backend" {
  TASK_ADAPTER_OVERRIDE=none run bash -c \
    'source scripts/lib/task-api.sh; load_task_adapter && task_adapter_name && declare -F task_health'
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]]
  [[ "$output" == *"task_health"* ]]
}

@test "dispatcher: gitlab alias maps to gitlab-tasks" {
  TASK_ADAPTER_OVERRIDE=gitlab run bash -c '
    source scripts/lib/task-api.sh
    if load_task_adapter 2>/tmp/task_alias_stderr; then
      task_adapter_name
    else
      cat /tmp/task_alias_stderr
    fi
    rm -f /tmp/task_alias_stderr
  '
  [[ "$output" == *"gitlab-tasks"* ]]
}

@test "dispatcher: github alias maps to github-tasks" {
  TASK_ADAPTER_OVERRIDE=github run bash -c '
    source scripts/lib/task-api.sh
    if load_task_adapter 2>/tmp/task_alias_stderr; then
      task_adapter_name
    else
      cat /tmp/task_alias_stderr
    fi
    rm -f /tmp/task_alias_stderr
  '
  [[ "$output" == *"github-tasks"* ]]
}

@test "every adapter file implements every contract function" {
  local missing=""
  for adapter in "$ADAPTERS_DIR"/*.sh; do
    local name
    name=$(basename "$adapter" .sh)
    for fn in "${CONTRACT_FUNCTIONS[@]}"; do
      if ! grep -qE "^(${fn}\(\)|function ${fn}( |\(|\{))" "$adapter"; then
        missing="${missing}${name}:${fn} "
      fi
    done
  done
  [ -z "$missing" ] || {
    echo "missing implementations: $missing" >&2
    return 1
  }
}

@test "none-backend functional smoke test" {
  TASK_ADAPTER_OVERRIDE=none run bash -c '
    source scripts/lib/task-api.sh
    load_task_adapter || exit 99
    task_get 42; rc_get=$?
    list=$(task_list)
    task_create "title" "body" 2>/dev/null; rc_create=$?
    task_health; rc_health=$?
    echo "rc_get=$rc_get list=$list rc_create=$rc_create rc_health=$rc_health"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc_get=2"* ]]
  [[ "$output" == *"list=[]"* ]]
  [[ "$output" == *"rc_create=3"* ]]
  [[ "$output" == *"rc_health=0"* ]]
}

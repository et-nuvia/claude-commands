#!/usr/bin/env bash
# task-backends/none.sh — no-op adapter for users not using external task tracking.
#
# Read functions return empty / [] / exit 2. Write functions return
# exit 3 (unsupported). task_health returns 0 — no backend means
# nothing to check.
#
# Don't source this file directly — go through scripts/lib/task-api.sh.

task_get()      { return 2; }
task_list()     { echo "[]"; }
task_search()   { echo "[]"; }
task_url()      { echo ""; }
task_health()   { return 0; }

task_create() {
  echo "none.sh: task backend is 'none' — cannot create tasks" >&2
  return 3
}

task_update() {
  echo "none.sh: task backend is 'none' — cannot update tasks" >&2
  return 3
}

task_close() {
  echo "none.sh: task backend is 'none' — cannot close tasks" >&2
  return 3
}

task_hold() {
  echo "none.sh: task backend is 'none' — cannot hold tasks" >&2
  return 3
}

task_resume() {
  echo "none.sh: task backend is 'none' — cannot resume tasks" >&2
  return 3
}

task_comment() {
  echo "none.sh: task backend is 'none' — cannot comment" >&2
  return 3
}

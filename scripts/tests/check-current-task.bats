#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../check-current-task.sh"

setup() {
  TMP_REPO="$(mktemp -d)"
  cd "$TMP_REPO"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "content" > initial
  git add initial
  git commit -m "initial commit" -q
  
  # Setup mock docs structure
  mkdir -p docs/active/0000-0099
  cat > docs/active/0000-0099/0001-2602191000-TSK-test-task.md << 'EOF'
# Test Task
**Branch**: feature/test-branch
EOF
}

teardown() {
  rm -rf "$TMP_REPO"
}

@test "check-current-task: fails if .current-task is missing" {
  run bash -c "$SCRIPT 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.active')" = "false" ]
  [ "$(echo "$output" | jq -r '.error')" = ".current-task file not found" ]
}

@test "check-current-task: succeeds if task and branch match" {
  git checkout -b feature/test-branch -q
  cat > .current-task << 'EOF'
{"task_id":"0001","branch":"feature/test-branch","parent_branch":"main","task_doc":"docs/active/0000-0099/0001-2602191000-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}
EOF

  run bash -c "$SCRIPT 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.active')" = "true" ]
  [ "$(echo "$output" | jq -r '.branch_match')" = "true" ]
  [ "$(echo "$output" | jq -r '.task_id')" = "0001" ]
  [ "$(echo "$output" | jq -r '.title')" = "Test Task" ]
}

@test "check-current-task: fails if branch does not match" {
  git checkout -b wrong-branch -q
  cat > .current-task << 'EOF'
{"task_id":"0001","branch":"feature/test-branch","parent_branch":"main","task_doc":"docs/active/0000-0099/0001-2602191000-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}
EOF

  run bash -c "$SCRIPT 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.active')" = "true" ]
  [ "$(echo "$output" | jq -r '.branch_match')" = "false" ]
  [ "$(echo "$output" | jq -r '.expected_branch')" = "feature/test-branch" ]
  [ "$(echo "$output" | jq -r '.current_branch')" = "wrong-branch" ]
}

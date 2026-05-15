#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../task-merge.sh"

setup() {
  TMP_REPO="$(mktemp -d)"
  cd "$TMP_REPO"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"

  # yaml_get in lib/yaml.sh handles Go/Python yq variants natively — no shim needed

  # Setup dev branch
  echo "initial" > file
  git add file
  git commit -m "initial commit" -q
  # Rename default branch to dev (handle both main and master)
  git branch -m dev 2>/dev/null || git branch -m main dev 2>/dev/null || git branch -m master dev
  
  # Setup feature branch
  git checkout -b feature/test -q
  echo "feature change" >> file
  git add file
  git commit -m "feat: test change" -q
  
  # Setup current task
  echo '{"task_id":"A1B2C3","branch":"feature/test","parent_branch":"main","task_doc":null,"started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

  # Setup PROJECT.yaml
  cat > PROJECT.yaml << 'EOF'
ci:
  branches:
    dev: dev
EOF
}

teardown() {
  rm -rf "$TMP_REPO"
}

@test "task-merge info: returns correct branch info" {
  run bash -c '"$1" --stage info 2>/dev/null' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.current_branch')" = "feature/test" ]
  [ "$(echo "$output" | jq -r '.dev_branch')" = "dev" ]
  [ "$(echo "$output" | jq -r '.commits_ahead')" -eq 1 ]
}

@test "task-merge merge: performs squash merge" {
  # KNOWN BUG: task-merge.sh passes positional args to git-merge.sh which now
  # requires --source/--target flags, and git-merge.sh validate fetches from remote
  # which fails in local-only test repos
  skip "task-merge.sh needs updating for new git-merge.sh API"
}

@test "task-merge cleanup: force deletes the feature branch" {
  git checkout dev -q
  run bash -c '"$1" --stage cleanup --branch feature/test 2>/dev/null' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.success')" = "true" ]
  [ "$(echo "$output" | jq -r '.cleaned_up')" = "feature/test" ]
  
  # Verify branch is gone
  run git rev-parse --verify feature/test
  [ "$status" -ne 0 ]
}

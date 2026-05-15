#!/usr/bin/env bats
# Contract test: every adapter in scripts/lib/git-platforms/ MUST
# implement every function defined in the contract. Add a new function
# to CONTRACT_FUNCTIONS below to enforce it across all adapters.

CONTRACT_FUNCTIONS=(
  git_issue_get
  git_issue_list
  git_issue_create
  git_issue_close
  git_issue_comment
  git_issue_label_add
  git_pr_find_for_branch
  git_pr_create
  git_pipeline_list
  git_pipeline_status
  git_pipeline_logs
  git_health
)

ADAPTERS_DIR="${BATS_TEST_DIRNAME}/../lib/git-platforms"

setup() {
  cd "${BATS_TEST_DIRNAME}/../.." || exit 1
}

@test "dispatcher: load_git_adapter rejects unknown platform" {
  GIT_ADAPTER_OVERRIDE=__unknown__ run bash -c \
    'source scripts/lib/git-api.sh; load_git_adapter'
  [ "$status" -ne 0 ]
}

@test "dispatcher: load_git_adapter accepts gitlab override" {
  GIT_ADAPTER_OVERRIDE=gitlab run bash -c \
    'source scripts/lib/git-api.sh; load_git_adapter && git_adapter_name'
  [ "$status" -eq 0 ]
  [ "$output" = "gitlab" ]
}

@test "every adapter file implements every contract function" {
  local missing=""
  for adapter in "$ADAPTERS_DIR"/*.sh; do
    local name
    name=$(basename "$adapter" .sh)
    for fn in "${CONTRACT_FUNCTIONS[@]}"; do
      if ! grep -qE "^${fn}\(\)" "$adapter"; then
        missing="${missing}${name}:${fn} "
      fi
    done
  done
  [ -z "$missing" ] || {
    echo "missing implementations: $missing" >&2
    return 1
  }
}

@test "every adapter is sourceable in isolation" {
  for adapter in "$ADAPTERS_DIR"/*.sh; do
    GIT_ADAPTER_OVERRIDE=$(basename "$adapter" .sh) run bash -c \
      "source scripts/lib/git-api.sh; load_git_adapter"
    [ "$status" -eq 0 ] || {
      echo "failed to source $adapter: $output" >&2
      return 1
    }
  done
}

#!/usr/bin/env bats
# Contract test: every adapter in scripts/lib/secrets-backends/ MUST
# implement every function defined in the contract. Add a new function
# to CONTRACT_FUNCTIONS below to enforce it across all adapters.

CONTRACT_FUNCTIONS=(
  sm_get
  sm_get_json
  sm_set
  sm_set_json
  sm_versions
  sm_restore
  sm_rotate_prepare
  sm_health
  sm_ui_url
)

ADAPTERS_DIR="${BATS_TEST_DIRNAME}/../lib/secrets-backends"

setup() {
  cd "${BATS_TEST_DIRNAME}/../.." || exit 1
}

@test "dispatcher: load_sm_adapter rejects unknown backend" {
  SM_ADAPTER_OVERRIDE=__unknown__ run bash -c \
    'source scripts/lib/secrets-api.sh; load_sm_adapter'
  [ "$status" -ne 0 ]
}

@test "dispatcher: load_sm_adapter accepts none backend" {
  SM_ADAPTER_OVERRIDE=none run bash -c \
    'source scripts/lib/secrets-api.sh; load_sm_adapter && sm_adapter_name && declare -F sm_health'
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]]
  [[ "$output" == *"sm_health"* ]]
}

@test "dispatcher: aws-secrets-manager alias maps to aws-sm" {
  # Only succeeds if aws CLI installed; otherwise the adapter file's
  # top-level guard returns 1. Assert that the dispatcher resolves the
  # alias even when load fails for environmental reasons.
  SM_ADAPTER_OVERRIDE=aws-secrets-manager run bash -c \
    'source scripts/lib/secrets-api.sh; load_sm_adapter 2>&1 || true; sm_adapter_name 2>/dev/null'
  # Either succeeds with "aws-sm" or fails with a recognizable error
  if [ "$status" -eq 0 ] && [ -n "$output" ]; then
    [[ "$output" == *"aws-sm"* ]]
  else
    # CLI missing path — verify the resolver picked the right filename
    SM_ADAPTER_OVERRIDE=aws-secrets-manager run bash -c \
      'source scripts/lib/secrets-api.sh; load_sm_adapter 2>&1 || true'
    [[ "$output" == *"aws-sm"* ]] || [[ "$output" == *"aws CLI"* ]]
  fi
}

@test "every adapter file implements every contract function" {
  # Accepts foo(), function foo {, function foo(), function foo (
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

@test "null adapter functional smoke test" {
  SM_ADAPTER_OVERRIDE=none run bash -c '
    source scripts/lib/secrets-api.sh
    load_sm_adapter || exit 99
    # Read functions: get returns 2 (not found); get_json returns {}
    sm_get prod /database PASSWORD; rc1=$?
    val=$(sm_get_json prod /database)
    # Write functions: return 3 (unsupported)
    sm_set prod /database PASSWORD foo 2>/dev/null; rc2=$?
    # Health: returns 0
    sm_health; rc3=$?
    echo "rc_get=$rc1 val_json=$val rc_set=$rc2 rc_health=$rc3"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc_get=2"* ]]
  [[ "$output" == *"val_json={}"* ]]
  [[ "$output" == *"rc_set=3"* ]]
  [[ "$output" == *"rc_health=0"* ]]
}

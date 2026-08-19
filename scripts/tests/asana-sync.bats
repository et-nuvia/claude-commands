#!/usr/bin/env bats
# Tests for lib/asana-sync.sh — inline Asana sync helpers used by task scripts.
# asana.sh is mocked via the ASANA_SH override.

LIB="${BATS_TEST_DIRNAME}/../lib/asana-sync.sh"

setup() {
  TMP_DIR="$(mktemp -d)"
  export HOME="$TMP_DIR"
  export ASANA_ACCESS_TOKEN="test-token"
  export CALL_LOG="$TMP_DIR/calls.log"

  # Mock asana.sh: log invocations, exit per MOCK_EXIT
  export ASANA_SH="$TMP_DIR/asana-mock.sh"
  cat > "$ASANA_SH" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
exit "${MOCK_EXIT:-0}"
MOCK
  chmod +x "$ASANA_SH"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# The field is addressed by the logical key `status`, never the display name:
# the live field is "Status Dev" in conformant projects, so a hardcoded
# "Status" resolved to nothing there.
@test "asana_sync_status_field addresses the logical status key" {
  run bash -c 'source "$1" && asana_sync_status_field 500 "in_progress" && cat "$CALL_LOG"' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"update-custom-field 500 --field status --value in_progress --if-supported"* ]]
}

@test "asana_sync_field sets any configured field by logical key" {
  run bash -c 'source "$1" && asana_sync_field 500 score 5 && cat "$CALL_LOG"' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"update-custom-field 500 --field score --value 5 --if-supported"* ]]
}

@test "asana_status_option_for maps lifecycle states to option keys" {
  run bash -c 'source "$1" && asana_status_option_for completed' _ "$LIB"
  [ "$output" = "done" ]
  run bash -c 'source "$1" && asana_status_option_for on_hold' _ "$LIB"
  [ "$output" = "hold" ]
  run bash -c 'source "$1" && asana_status_option_for in_progress' _ "$LIB"
  [ "$output" = "in_progress" ]
}

@test "asana_sync_section resolves a logical section to its GID" {
  cat > "$TMP_DIR/PROJECT.yaml" <<'YAML'
task_management:
  asana:
    sections:
      backlog:
        gid: "999888777"
        name: "Backlog"
    section_transitions:
      start: "backlog"
YAML
  run bash -c 'cd "$2" && source "$1" && asana_sync_section 500 backlog && cat "$CALL_LOG"' _ "$LIB" "$TMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"move-task-to-section 500 --section 999888777"* ]]
}

@test "asana_sync_section_for_operation maps an operation to its section" {
  cat > "$TMP_DIR/PROJECT.yaml" <<'YAML'
task_management:
  asana:
    sections:
      current_sprint:
        gid: "111222333"
        name: "Current Sprint"
    section_transitions:
      start: "current_sprint"
YAML
  run bash -c 'cd "$2" && source "$1" && asana_sync_section_for_operation 500 start && cat "$CALL_LOG"' _ "$LIB" "$TMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"move-task-to-section 500 --section 111222333"* ]]
}

# A project not yet on the standard layout has no sections block; that must be
# a no-op rather than a failure that aborts the caller's sync.
@test "asana_sync_section is a no-op when no sections are configured" {
  printf 'task_management:\n  asana:\n    project: "x"\n' > "$TMP_DIR/PROJECT.yaml"
  run bash -c 'cd "$2" && source "$1" && asana_sync_section 500 backlog' _ "$LIB" "$TMP_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "asana_sync_completed calls update-task with flag" {
  run bash -c 'source "$1" && asana_sync_completed 500 false && cat "$CALL_LOG"' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"update-task 500 --completed false"* ]]
}

@test "asana_sync_completed rejects invalid flag" {
  run bash -c 'source "$1" && asana_sync_completed 500 maybe' _ "$LIB"
  [ "$status" -ne 0 ]
}

@test "asana_sync_comment calls add-comment with text" {
  run bash -c 'source "$1" && asana_sync_comment 500 "hold: waiting on vendor" && cat "$CALL_LOG"' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add-comment 500 --text hold: waiting on vendor"* ]]
}

@test "helpers return non-zero when shim fails" {
  export MOCK_EXIT=1
  run bash -c 'source "$1" && asana_sync_status_field 500 "Done"' _ "$LIB"
  [ "$status" -ne 0 ]
}

@test "helpers return non-zero with empty gid" {
  run bash -c 'source "$1" && asana_sync_status_field "" "Done"' _ "$LIB"
  [ "$status" -ne 0 ]
}

@test "asana_sync_available fails when shim missing" {
  export ASANA_SH="$TMP_DIR/does-not-exist.sh"
  run bash -c 'source "$1" && asana_sync_available' _ "$LIB"
  [ "$status" -ne 0 ]
}

@test "asana_sync_available fails without any token" {
  unset ASANA_ACCESS_TOKEN
  run bash -c 'source "$1" && asana_sync_available' _ "$LIB"
  [ "$status" -ne 0 ]
}

#!/usr/bin/env bash
# secrets-backends/none.sh — no-op adapter for users not using a secrets backend.
# (File is named "none.sh" rather than "null.sh" to avoid collision with
# the string "null" that yq returns for missing YAML keys.)
#
# Read functions return empty + exit 2 (not found). Write/restore
# functions return exit 3 (unsupported) so callers can detect a
# misconfigured project trying to write secrets when none should exist.
# sm_health returns 0 — no backend means nothing to check.
#
# Don't source this file directly — go through scripts/lib/secrets-api.sh.

sm_get()              { return 2; }
sm_get_json()         { echo "{}"; }
sm_ui_url()           { echo ""; }

sm_set() {
  echo "null.sh: secrets backend is 'none' — cannot write secrets" >&2
  return 3
}

sm_set_json() {
  echo "null.sh: secrets backend is 'none' — cannot write secrets" >&2
  return 3
}

sm_versions()         { echo "[]"; }

sm_restore() {
  echo "null.sh: secrets backend is 'none' — cannot restore" >&2
  return 3
}

sm_rotate_prepare()   { return 0; }
sm_health()           { return 0; }

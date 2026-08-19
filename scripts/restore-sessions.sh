#!/usr/bin/env bash
# restore-sessions.sh — after a forced reboot, pick which crashed Claude Code
# sessions to bring back and relaunch them all in one go.
#
#   restore-sessions.sh          interactive picker
#   restore-sessions.sh --list   non-interactive listing (no TUI)
#
# Suggested alias:  alias rcs='~/.claude/scripts/restore-sessions.sh'

set -euo pipefail

readonly LIB_DIR="${HOME}/.claude/scripts/lib"

if [[ "${1:-}" == "--list" ]]; then
  exec python3 "${LIB_DIR}/session_registry.py" list
fi

exec python3 "${LIB_DIR}/restore_sessions_tui.py" "$@"

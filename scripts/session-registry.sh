#!/usr/bin/env bash
# session-registry.sh — track running Claude Code sessions so a forced reboot
# does not lose them.
#
# Hook usage (SessionStart / SessionEnd, payload on stdin):
#   session-registry.sh hook-start
#   session-registry.sh hook-end
#
# CLI usage:
#   session-registry.sh list [--json]
#   session-registry.sh restore <n|session_id> [--print]
#   session-registry.sh clear <n|session_id|--all>
#   session-registry.sh sweep
#
# All logic lives in lib/session_registry.py. Hook modes never fail the session.

set -uo pipefail

readonly LIB="${HOME}/.claude/scripts/lib/session_registry.py"

case "${1:-}" in
  hook-start|hook-end)
    python3 "${LIB}" "$@" 2>/dev/null || true
    exit 0
    ;;
  *)
    exec python3 "${LIB}" "$@"
    ;;
esac

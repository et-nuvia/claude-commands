#!/usr/bin/env bash
# rename-session.sh — set the current Claude Code session's title (same as /rename)
# so remote/session pickers show the task being worked on.
#
# Usage: rename-session.sh --title "B28407 — specialized agents" [--session-id <uuid>] [--dir <project-dir>]
#   --title       Required. New session title.
#   --session-id  Optional. Defaults to $CLAUDE_CODE_SESSION_ID (set inside Claude Code Bash calls).
#   --dir         Optional. Project directory whose session store holds the transcript;
#                 omitted → SDK searches all project directories.
#
# Output: single JSON object {status, session_id, title}. Never fails the calling
# workflow: rename problems exit 0 with status=error so task-start flows continue.

set -euo pipefail

title=""
session_id="${CLAUDE_CODE_SESSION_ID:-}"
dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="${2:-}"; shift 2 ;;
    --session-id) session_id="${2:-}"; shift 2 ;;
    --dir) dir="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

emit() {
  local status="$1" msg="$2"
  jq -cn --arg status "${status}" --arg session_id "${session_id}" --arg title "${title}" --arg message "${msg}" \
    '{status: $status, session_id: $session_id, title: $title, message: $message}'
}

if [[ -z "${title// /}" ]]; then
  emit error "missing --title"
  exit 0
fi

if [[ -z "${session_id}" ]]; then
  emit error "no session id (--session-id or \$CLAUDE_CODE_SESSION_ID)"
  exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
  emit error "uv not found on PATH"
  exit 0
fi

if RENAME_TITLE="${title}" RENAME_SESSION_ID="${session_id}" RENAME_DIR="${dir}" \
  uv run --quiet --with claude-agent-sdk python - <<'PY' 2>/dev/null
import os
from claude_agent_sdk import rename_session

kwargs = {}
if os.environ.get("RENAME_DIR"):
    kwargs["directory"] = os.environ["RENAME_DIR"]
rename_session(os.environ["RENAME_SESSION_ID"], os.environ["RENAME_TITLE"], **kwargs)
PY
then
  emit ok "session renamed"
else
  emit error "rename_session failed (session not found or SDK error)"
fi

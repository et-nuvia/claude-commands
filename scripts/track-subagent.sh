#!/usr/bin/env bash
# track-subagent.sh — Hook script for SubagentStart/SubagentStop events
#
# Logs subagent lifecycle events to the same daily tracking files as track-command.sh.
# Receives hook JSON input on stdin from Claude Code.
#
# SubagentStart input: { session_id, agent_id, agent_type, cwd, ... }
# SubagentStop input:  { session_id, agent_id, agent_type, agent_transcript_path, ... }
#
# Logged fields: parent_command, agent_id, agent_type, model, tokens, cost, duration

set -euo pipefail

readonly TRACKING_DIR="${HOME}/.claude/tracking"
readonly SESSION_FILE="${HOME}/.claude/.tracking-session"

mkdir -p "${TRACKING_DIR}"

# Read hook JSON from stdin
HOOK_INPUT="$(cat)"

# ─── Helpers ──────────────────────────────────────────────────────────────────

get_timestamp() { date +"%Y-%m-%dT%H:%M:%S%z"; }
get_date()      { date +"%Y-%m-%d"; }

append_entry() {
  local tracking_file="$1"
  TRACKING_FILE="${tracking_file}" python3 - <<'PYEOF'
import json, os

tracking_file = os.environ["TRACKING_FILE"]
entry_json    = os.environ["ENTRY_JSON"]
entry         = json.loads(entry_json)

data = []
try:
    with open(tracking_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass

data.append(entry)

with open(tracking_file, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ─── Parse hook input ─────────────────────────────────────────────────────────

HOOK_EVENT=$(echo "${HOOK_INPUT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hook_event_name',''))" 2>/dev/null || echo "")
AGENT_ID=$(echo "${HOOK_INPUT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent_id',''))" 2>/dev/null || echo "")
AGENT_TYPE=$(echo "${HOOK_INPUT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent_type',''))" 2>/dev/null || echo "")
SESSION_ID=$(echo "${HOOK_INPUT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

# Get parent command from active tracking session (if any)
PARENT_COMMAND=""
if [[ -f "${SESSION_FILE}" ]]; then
  PARENT_COMMAND=$(python3 -c "import json; print(json.load(open('${SESSION_FILE}')).get('command',''))" 2>/dev/null || true)
fi

TIMESTAMP="$(get_timestamp)"
TODAY="$(get_date)"
TRACKING_FILE="${TRACKING_DIR}/${TODAY}.json"

# ─── SubagentStart ────────────────────────────────────────────────────────────

if [[ "${HOOK_EVENT}" == "SubagentStart" ]]; then

  # Save start time for duration calculation at stop
  SUBAGENT_SESSION_DIR="${HOME}/.claude/.subagent-sessions"
  mkdir -p "${SUBAGENT_SESSION_DIR}"
  echo "${TIMESTAMP}" > "${SUBAGENT_SESSION_DIR}/${AGENT_ID}"

  ENTRY_JSON=$(AGENT_ID="${AGENT_ID}" AGENT_TYPE="${AGENT_TYPE}" SESSION_ID="${SESSION_ID}" \
  PARENT_COMMAND="${PARENT_COMMAND}" TIMESTAMP="${TIMESTAMP}" python3 - <<'PYEOF'
import json, os
e = os.environ
entry = {
    "type":           "subagent",
    "status":         "started",
    "agent_id":       e["AGENT_ID"],
    "agent_type":     e["AGENT_TYPE"],
    "session_id":     e["SESSION_ID"],
    "parent_command": e["PARENT_COMMAND"] or None,
    "timestamp":      e["TIMESTAMP"],
}
print(json.dumps(entry))
PYEOF
)

  export ENTRY_JSON
  append_entry "${TRACKING_FILE}"

# ─── SubagentStop ─────────────────────────────────────────────────────────────

elif [[ "${HOOK_EVENT}" == "SubagentStop" ]]; then

  TRANSCRIPT_PATH=$(echo "${HOOK_INPUT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent_transcript_path',''))" 2>/dev/null || echo "")

  # Calculate duration from saved start time
  SUBAGENT_SESSION_FILE="${HOME}/.claude/.subagent-sessions/${AGENT_ID}"
  START_TIME=""
  if [[ -f "${SUBAGENT_SESSION_FILE}" ]]; then
    START_TIME="$(cat "${SUBAGENT_SESSION_FILE}")"
    rm -f "${SUBAGENT_SESSION_FILE}"
  fi

  # Parse transcript for model, token usage, and cost via the shared library
  # (same parser used by track-session.sh, so subagent + session fields match).
  USAGE_JSON="$(python3 "${HOME}/.claude/scripts/lib/transcript-usage.py" "${TRANSCRIPT_PATH}" 2>/dev/null || echo '{}')"

  ENTRY_JSON=$(AGENT_ID="${AGENT_ID}" AGENT_TYPE="${AGENT_TYPE}" SESSION_ID="${SESSION_ID}" \
  PARENT_COMMAND="${PARENT_COMMAND}" TIMESTAMP="${TIMESTAMP}" \
  START_TIME="${START_TIME}" USAGE_JSON="${USAGE_JSON}" python3 - <<'PYEOF'
import json, os, re
from datetime import datetime, timezone

e = os.environ

# Calculate duration
duration = 0
start_time = e.get("START_TIME", "")
if start_time:
    def parse_ts(ts):
        ts = re.sub(r'([+-]\d{2})(\d{2})$', r'\1:\2', ts)
        try:
            return datetime.fromisoformat(ts)
        except Exception:
            return datetime.now(timezone.utc)
    diff = parse_ts(e["TIMESTAMP"]) - parse_ts(start_time)
    duration = int(abs(diff.total_seconds()))

usage = json.loads(e.get("USAGE_JSON") or "{}")

result = {
    "type":             "subagent",
    "status":           "completed",
    "agent_id":         e["AGENT_ID"],
    "agent_type":       e["AGENT_TYPE"],
    "session_id":       e["SESSION_ID"],
    "parent_command":   e["PARENT_COMMAND"] or None,
    "timestamp":        e["TIMESTAMP"],
    "duration_seconds": duration,
}
result.update(usage)
print(json.dumps(result))
PYEOF
)

  export ENTRY_JSON
  append_entry "${TRACKING_FILE}"

fi

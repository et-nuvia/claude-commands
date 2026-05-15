#!/usr/bin/env bash
# track-command.sh — Log command lifecycle events to daily JSON tracking files
#
# Usage:
#   track-command.sh --command "command-name" --event start [--project <name>]
#   track-command.sh --command "command-name" --event complete --model "claude-sonnet-4-6" --complexity 3 --tokens 45000 --cost 0.54
#   track-command.sh --command "command-name" --event error --model "claude-sonnet-4-6" --error-msg "description"

set -euo pipefail

readonly TRACKING_DIR="${HOME}/.claude/tracking"
readonly SESSION_FILE="${HOME}/.claude/.tracking-session"
readonly SETTINGS_FILE="${HOME}/.claude/settings.json"

# ─── Argument Parsing ─────────────────────────────────────────────────────────

COMMAND_NAME="unknown"
EVENT_TYPE="start"
PROJECT=""
MODEL=""
COMPLEXITY=""
TOKENS=""
COST=""
ERROR_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command)    COMMAND_NAME="$2"; shift 2 ;;
    --event)      EVENT_TYPE="$2";   shift 2 ;;
    --project)    PROJECT="$2";      shift 2 ;;
    --model)      MODEL="$2";        shift 2 ;;
    --complexity) COMPLEXITY="$2";   shift 2 ;;
    --tokens)     TOKENS="$2";       shift 2 ;;
    --cost)       COST="$2";         shift 2 ;;
    --error-msg)  ERROR_MSG="$2";    shift 2 ;;
    *) echo "Unknown option: $1" >&2; shift ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

generate_id() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8
  else
    printf '%08x' "$(( $(date +%s) + RANDOM ))"
  fi
}

get_timestamp() { date +"%Y-%m-%dT%H:%M:%S%z"; }
get_date()      { date +"%Y-%m-%d"; }

detect_project() {
  if [[ -f "PROJECT.yaml" ]]; then
    python3 - <<'PYEOF'
import re
with open("PROJECT.yaml") as f:
    content = f.read()
m = re.search(r'^name:\s*(.+)$', content, re.MULTILINE)
print(m.group(1).strip() if m else "")
PYEOF
  elif git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    git remote get-url origin 2>/dev/null | sed 's|.*/||; s|\.git$||' || true
  fi
}

get_selected_model() {
  [[ -f "${SETTINGS_FILE}" ]] || { echo "unknown"; return; }
  python3 - <<PYEOF
import json
with open("${SETTINGS_FILE}") as f:
    d = json.load(f)
print(d.get("model", "unknown"))
PYEOF
}

get_folder() { basename "$(pwd)"; }

append_entry() {
  # Writes a JSON entry dict (passed via env var ENTRY_JSON) into the daily file
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

# ─── Ensure Tracking Dir ──────────────────────────────────────────────────────

mkdir -p "${TRACKING_DIR}"

# ─── start ────────────────────────────────────────────────────────────────────

if [[ "${EVENT_TYPE}" == "start" ]]; then
  EVENT_ID="$(generate_id)"
  SESSION_ID="$(generate_id)"
  TIMESTAMP="$(get_timestamp)"
  TODAY="$(get_date)"
  FOLDER="$(get_folder)"

  if [[ -z "${PROJECT}" ]]; then
    PROJECT="$(detect_project)" || true
  fi
  [[ -z "${PROJECT}" ]] && PROJECT="${FOLDER}"

  # Persist session for the matching complete/error call
  COMMAND_NAME="${COMMAND_NAME}" SESSION_ID="${SESSION_ID}" EVENT_ID="${EVENT_ID}" \
  TIMESTAMP="${TIMESTAMP}" PROJECT="${PROJECT}" python3 - <<'PYEOF'
import json, os
data = {
    "session_id": os.environ["SESSION_ID"],
    "event_id":   os.environ["EVENT_ID"],
    "start_time": os.environ["TIMESTAMP"],
    "command":    os.environ["COMMAND_NAME"],
    "project":    os.environ["PROJECT"],
}
with open(os.path.expanduser("~/.claude/.tracking-session"), "w") as f:
    json.dump(data, f)
PYEOF

  TRACKING_FILE="${TRACKING_DIR}/${TODAY}.json"

  ENTRY_JSON=$(COMMAND_NAME="${COMMAND_NAME}" SESSION_ID="${SESSION_ID}" \
  EVENT_ID="${EVENT_ID}" TIMESTAMP="${TIMESTAMP}" PROJECT="${PROJECT}" FOLDER="${FOLDER}" \
  python3 - <<'PYEOF'
import json, os
entry = {
    "event_id":   os.environ["EVENT_ID"],
    "session_id": os.environ["SESSION_ID"],
    "command":    os.environ["COMMAND_NAME"],
    "project":    os.environ["PROJECT"],
    "folder":     os.environ["FOLDER"],
    "status":     "started",
    "timestamp":  os.environ["TIMESTAMP"],
}
print(json.dumps(entry))
PYEOF
)

  export ENTRY_JSON
  append_entry "${TRACKING_FILE}"
  echo "Tracking started: ${COMMAND_NAME} [session=${SESSION_ID}]"

# ─── complete / error ─────────────────────────────────────────────────────────

elif [[ "${EVENT_TYPE}" == "complete" || "${EVENT_TYPE}" == "error" ]]; then
  if [[ ! -f "${SESSION_FILE}" ]]; then
    echo "Warning: No active tracking session (${SESSION_FILE} missing)" >&2
    exit 0
  fi

  TIMESTAMP="$(get_timestamp)"
  TODAY="$(get_date)"
  FOLDER="$(get_folder)"
  SELECTED_MODEL="$(get_selected_model)"
  SESSION_DATA="$(cat "${SESSION_FILE}")"

  # Parse session fields
  SESSION_ID=$(   echo "${SESSION_DATA}" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])")
  START_TIME=$(   echo "${SESSION_DATA}" | python3 -c "import json,sys; print(json.load(sys.stdin)['start_time'])")
  SESSION_CMD=$(  echo "${SESSION_DATA}" | python3 -c "import json,sys; print(json.load(sys.stdin)['command'])")
  SESSION_PROJ=$( echo "${SESSION_DATA}" | python3 -c "import json,sys; print(json.load(sys.stdin)['project'])")

  DURATION=$(START_TIME="${START_TIME}" TIMESTAMP="${TIMESTAMP}" python3 - <<'PYEOF'
import os, re
from datetime import datetime, timezone

def parse_ts(ts):
    ts = re.sub(r'([+-]\d{2})(\d{2})$', r'\1:\2', ts)
    try:
        return datetime.fromisoformat(ts)
    except Exception:
        return datetime.now(timezone.utc)

diff = parse_ts(os.environ["TIMESTAMP"]) - parse_ts(os.environ["START_TIME"])
print(int(abs(diff.total_seconds())))
PYEOF
)

  TRACKING_FILE="${TRACKING_DIR}/${TODAY}.json"

  ENTRY_JSON=$(SESSION_ID="${SESSION_ID}" SESSION_CMD="${SESSION_CMD}" \
  SESSION_PROJ="${SESSION_PROJ}" TIMESTAMP="${TIMESTAMP}" FOLDER="${FOLDER}" \
  EVENT_TYPE="${EVENT_TYPE}" MODEL="${MODEL}" SELECTED_MODEL="${SELECTED_MODEL}" \
  DURATION="${DURATION}" COMPLEXITY="${COMPLEXITY}" TOKENS="${TOKENS}" \
  COST="${COST}" ERROR_MSG="${ERROR_MSG}" python3 - <<'PYEOF'
import json, os

e = os.environ
entry = {
    "session_id":     e["SESSION_ID"],
    "command":        e["SESSION_CMD"],
    "project":        e["SESSION_PROJ"],
    "folder":         e["FOLDER"],
    "status":         e["EVENT_TYPE"] + "d",
    "timestamp":      e["TIMESTAMP"],
    "model":          e["MODEL"] or None,
    "selected_model": e["SELECTED_MODEL"],
    "duration_seconds": int(e["DURATION"] or 0),
}

if e["COMPLEXITY"]: entry["complexity"]        = int(e["COMPLEXITY"])
if e["TOKENS"]:     entry["tokens_estimated"]  = int(e["TOKENS"])
if e["COST"]:       entry["cost_estimated"]    = float(e["COST"])
if e["ERROR_MSG"]:  entry["error_msg"]         = e["ERROR_MSG"]

print(json.dumps(entry))
PYEOF
)

  export ENTRY_JSON
  append_entry "${TRACKING_FILE}"
  rm -f "${SESSION_FILE}"
  echo "Tracking ${EVENT_TYPE}d: ${SESSION_CMD} [duration=${DURATION}s]"

else
  echo "Error: Unknown event type '${EVENT_TYPE}'. Use: start, complete, error" >&2
  exit 1
fi

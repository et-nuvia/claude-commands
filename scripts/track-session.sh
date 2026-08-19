#!/usr/bin/env bash
set -uo pipefail
# track-session.sh — Hook script for the SessionEnd event
#
# Records main-session token usage + cost the same way track-subagent.sh records
# subagents, by parsing the session transcript JSONL. SessionEnd fires once per
# session, so this appends exactly one `type: session` record per session — no
# per-turn re-parsing, no upsert race.
#
# SessionEnd hook input (stdin JSON): { session_id, transcript_path, cwd, reason, ... }
#
# Fail-safe: never errors the session. Any problem → silent exit 0.

set -uo pipefail

readonly TRACKING_DIR="${HOME}/.claude/tracking"
readonly SESSION_FILE="${HOME}/.claude/.tracking-session"
readonly LIB_DIR="${HOME}/.claude/scripts/lib"

mkdir -p "${TRACKING_DIR}" 2>/dev/null || exit 0

HOOK_INPUT="$(cat 2>/dev/null || true)"

# ─── Parse hook input ─────────────────────────────────────────────────────────

read_field() {
  echo "${HOOK_INPUT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || echo ""
}

SESSION_ID="$(read_field session_id)"
TRANSCRIPT_PATH="$(read_field transcript_path)"
REASON="$(read_field reason)"
CWD="$(read_field cwd)"

# Fall back to env if the hook payload omits these fields.
[[ -z "${SESSION_ID}" ]] && SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
[[ -z "${CWD}" ]] && CWD="${PWD:-}"

# If SessionEnd does not carry transcript_path (unverified across CLI versions),
# reconstruct it: transcripts live at ~/.claude/projects/<enc>/<session_id>.jsonl
# where <enc> is the absolute cwd with every '/' and '.' replaced by '-'.
if [[ -z "${TRANSCRIPT_PATH}" && -n "${SESSION_ID}" && -n "${CWD}" ]]; then
  enc="$(printf '%s' "${CWD}" | sed 's#[/.]#-#g')"
  candidate="${HOME}/.claude/projects/${enc}/${SESSION_ID}.jsonl"
  [[ -f "${candidate}" ]] && TRANSCRIPT_PATH="${candidate}"
fi

# Project/command context from the active tracking session, if any
PROJECT=""
PARENT_COMMAND=""
if [[ -f "${SESSION_FILE}" ]]; then
  PROJECT=$(python3 -c "import json; print(json.load(open('${SESSION_FILE}')).get('project',''))" 2>/dev/null || true)
  PARENT_COMMAND=$(python3 -c "import json; print(json.load(open('${SESSION_FILE}')).get('command',''))" 2>/dev/null || true)
fi
[[ -z "${PROJECT}" && -n "${CWD}" ]] && PROJECT="$(basename "${CWD}")"
# Strip surrounding quotes that can leak in from a quoted PROJECT.yaml `name:` value
PROJECT="${PROJECT%\"}"; PROJECT="${PROJECT#\"}"

TIMESTAMP="$(date +"%Y-%m-%dT%H:%M:%S%z")"
TODAY="$(date +"%Y-%m-%d")"
TRACKING_FILE="${TRACKING_DIR}/${TODAY}.json"

# ─── Parse usage via shared library ───────────────────────────────────────────

USAGE_JSON="$(python3 "${LIB_DIR}/transcript-usage.py" "${TRANSCRIPT_PATH}" 2>/dev/null || echo '{}')"

# Skip writing a useless empty record (no transcript / zero tokens)
TOTAL=$(echo "${USAGE_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_tokens',0) or 0)" 2>/dev/null || echo 0)
[[ "${TOTAL}" == "0" ]] && exit 0

# ─── Build + append record ────────────────────────────────────────────────────

ENTRY_JSON=$(SESSION_ID="${SESSION_ID}" PROJECT="${PROJECT}" PARENT_COMMAND="${PARENT_COMMAND}" \
  REASON="${REASON}" TIMESTAMP="${TIMESTAMP}" USAGE_JSON="${USAGE_JSON}" python3 - <<'PYEOF'
import json, os
e = os.environ
usage = json.loads(e.get("USAGE_JSON") or "{}")
entry = {
    "type":           "session",
    "status":         "completed",
    "session_id":     e["SESSION_ID"],
    "project":        e["PROJECT"] or None,
    "parent_command": e["PARENT_COMMAND"] or None,
    "reason":         e["REASON"] or None,
    "timestamp":      e["TIMESTAMP"],
}
entry.update(usage)
print(json.dumps(entry))
PYEOF
)

TRACKING_FILE="${TRACKING_FILE}" ENTRY_JSON="${ENTRY_JSON}" python3 - <<'PYEOF' 2>/dev/null || exit 0
import json, os
tf = os.environ["TRACKING_FILE"]
entry = json.loads(os.environ["ENTRY_JSON"])
data = []
try:
    with open(tf) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass
data.append(entry)
with open(tf, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

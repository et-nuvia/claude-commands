#!/usr/bin/env bash
# Cross-platform Claude Code notification hook.
# Works on macOS, WSL Debian (with Windows interop), and native Linux.
# Invoked by Notification and Stop hooks; reads hook JSON on stdin.
set -euo pipefail

EVENT_TYPE="${1:-notification}"

INPUT=""
if [ ! -t 0 ]; then
    INPUT=$(cat || true)
fi

extract_field() {
    local field="$1"
    local value=""
    if [ -n "$INPUT" ]; then
        if command -v jq >/dev/null 2>&1; then
            value=$(printf '%s' "$INPUT" | jq -r ".${field} // empty" 2>/dev/null || true)
        elif command -v python3 >/dev/null 2>&1; then
            value=$(printf '%s' "$INPUT" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('${field}','') or '')
except Exception:
    pass" 2>/dev/null || true)
        fi
    fi
    printf '%s' "$value"
}

CWD=$(extract_field cwd)
CWD="${CWD:-$(pwd)}"
PROJECT=$(basename "$CWD")

MESSAGE_RAW=$(extract_field message)
TRANSCRIPT_PATH=$(extract_field transcript_path)

# Detect "parked, not done" state by inspecting the last assistant turn of the
# transcript. We consider Claude parked (not truly done) if its final turn:
#   - scheduled a wakeup (ScheduleWakeup), or
#   - kicked off background work (run_in_background: true on Bash/Agent) that
#     has no matching completion/kill in subsequent messages.
detect_parked_state() {
    local transcript="$1"
    [ -n "$transcript" ] && [ -r "$transcript" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$transcript" <<'PY' 2>/dev/null || return 1
import json, sys

path = sys.argv[1]
try:
    lines = open(path, 'r', encoding='utf-8', errors='replace').readlines()
except OSError:
    sys.exit(1)

# Find the LAST assistant message.
last_assistant = None
for line in reversed(lines):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    msg = rec.get('message') or rec
    if rec.get('type') == 'assistant' or msg.get('role') == 'assistant':
        last_assistant = msg
        break

if not last_assistant:
    sys.exit(1)

content = last_assistant.get('content') or []
if not isinstance(content, list):
    sys.exit(1)

bg_shell_ids = []
parked_reason = None

for block in content:
    if not isinstance(block, dict) or block.get('type') != 'tool_use':
        continue
    name = block.get('name') or ''
    inp = block.get('input') or {}
    if name == 'ScheduleWakeup':
        parked_reason = 'scheduled wakeup'
        break
    if name in ('Bash', 'Agent') and inp.get('run_in_background') is True:
        bg_shell_ids.append(block.get('id'))

# If any backgrounded work was launched in the last turn, treat as parked.
# (A finished bg job would normally have been acknowledged in an earlier turn,
# making the last turn no longer the launching turn.)
if not parked_reason and bg_shell_ids:
    parked_reason = 'background work running'

if parked_reason:
    print(parked_reason)
    sys.exit(0)
sys.exit(1)
PY
}

case "$EVENT_TYPE" in
    stop)
        TITLE="Claude Code: ${PROJECT}"
        PARKED_REASON=$(detect_parked_state "$TRANSCRIPT_PATH" || true)
        if [ -n "$PARKED_REASON" ]; then
            MESSAGE="Waiting (${PARKED_REASON})"
            SOUND_MAC="Tink"
            SOUND_WIN="C:\\Windows\\Media\\Windows Notify.wav"
        else
            MESSAGE="Task completed"
            SOUND_MAC="Hero"
            SOUND_WIN="C:\\Windows\\Media\\tada.wav"
        fi
        ;;
    notification|*)
        TITLE="Claude Code: ${PROJECT}"
        MESSAGE="${MESSAGE_RAW:-Waiting for your input}"
        SOUND_MAC="Glass"
        SOUND_WIN="C:\\Windows\\Media\\Windows Notify System Generic.wav"
        ;;
esac

# Emit bell FIRST so VS Code shows the yellow bell tab icon immediately.
printf '\a' || true

escape_for_osascript() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_for_powershell() {
    # Escape single quotes for PowerShell single-quoted strings (double them).
    printf '%s' "$1" | sed "s/'/''/g"
}

OS="$(uname -s 2>/dev/null || echo unknown)"

if [ "$OS" = "Darwin" ]; then
    T=$(escape_for_osascript "$TITLE")
    M=$(escape_for_osascript "$MESSAGE")
    osascript -e "display notification \"$M\" with title \"$T\" sound name \"$SOUND_MAC\"" >/dev/null 2>&1 || true
elif grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
    T=$(escape_for_powershell "$TITLE")
    M=$(escape_for_powershell "$MESSAGE")
    if command -v wsl-notify-send.exe >/dev/null 2>&1; then
        wsl-notify-send.exe --category "$TITLE" "$MESSAGE" >/dev/null 2>&1 || true
    elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "New-BurntToastNotification -Text '$T','$M'" >/dev/null 2>&1 \
            || powershell.exe -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('$M', '$T')" >/dev/null 2>&1 \
            || true
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
        ( powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '$SOUND_WIN').PlaySync()" >/dev/null 2>&1 & ) || true
    fi
else
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$TITLE" "$MESSAGE" >/dev/null 2>&1 || true
    fi
fi

exit 0

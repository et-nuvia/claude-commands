#!/usr/bin/env bash
# tdd-log.sh — Observability JSONL logger for the TDD PreToolUse hook (DSN 0C4B72 Decision 7)
#
# Provides two functions:
#   tdd_log <decision> <reason> <file> <subtask> <tdd_required>
#       Appends one JSON line to ~/.claude/logs/tdd-hook.log.
#       Schema: {ts, tool, file, decision, reason, subtask, tdd_required}
#       Tool name is read from env TDD_HOOK_TOOL (set by the hook script).
#
#   tdd_log_rotate
#       Renames tdd-hook.log → .log.1 (and .log.1 → .log.2, dropping .log.2)
#       when the active log exceeds 10 MB. Called automatically by tdd_log
#       before each append.
#
# Both functions are FAIL-SILENT — logging errors must never block the
# parent hook from making its allow/block decision. This is a safety
# library: every code path swallows errors and returns 0.
#
# Designed to be sourced. No `set -e` here on purpose — caller controls
# its own error handling.

# Override target via env for tests (TDD_LOG_FILE) or production default
TDD_LOG_FILE_DEFAULT="${HOME}/.claude/logs/tdd-hook.log"
TDD_LOG_MAX_BYTES="${TDD_LOG_MAX_BYTES:-10485760}"  # 10 MB

# Resolve the active log file path (lets tests redirect via env)
_tdd_log_path() {
    echo "${TDD_LOG_FILE:-$TDD_LOG_FILE_DEFAULT}"
}

# Portable byte-size of a regular file. Echoes 0 if the file is missing
# or stat fails. Tries GNU stat first, then BSD stat.
_tdd_log_size() {
    local f="$1"
    [[ -f "$f" ]] || { echo 0; return 0; }
    local sz
    sz=$(stat -c %s "$f" 2>/dev/null) || sz=$(stat -f %z "$f" 2>/dev/null) || sz=0
    echo "${sz:-0}"
}

# Rotate: .log.1 → .log.2 (drop existing .log.2), .log → .log.1.
# Called when current log exceeds TDD_LOG_MAX_BYTES. Fail-silent.
tdd_log_rotate() {
    local log
    log=$(_tdd_log_path)
    [[ -f "$log" ]] || return 0
    {
        [[ -f "${log}.1" ]] && mv -f "${log}.1" "${log}.2"
        mv -f "$log" "${log}.1"
    } 2>/dev/null || true
    return 0
}

# Append one JSON line to the log. Always returns 0 — never blocks the caller.
# Args: $1=decision (allow|block) $2=reason $3=file $4=subtask $5=tdd_required (true|false)
tdd_log() {
    {
        local log dir size
        log=$(_tdd_log_path)
        dir="${log%/*}"

        # Ensure log directory exists; bail silently if creation fails
        [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0

        # Rotate if oversized
        size=$(_tdd_log_size "$log")
        if [[ "$size" -gt "$TDD_LOG_MAX_BYTES" ]]; then
            tdd_log_rotate
        fi

        # Build the JSON line. Use jq if available (handles escaping correctly);
        # fall back to a printf with naive escaping for portability.
        local line
        if command -v jq >/dev/null 2>&1; then
            line=$(jq -nc \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg tool "${TDD_HOOK_TOOL:-unknown}" \
                --arg file "${3:-}" \
                --arg decision "${1:-}" \
                --arg reason "${2:-}" \
                --arg subtask "${4:-}" \
                --argjson tdd_required "$( [[ "${5:-}" == "true" ]] && echo true || echo false )" \
                '{ts:$ts, tool:$tool, file:$file, decision:$decision, reason:$reason, subtask:$subtask, tdd_required:$tdd_required}' \
                2>/dev/null) || line=""
        fi

        # Fallback if jq missing or failed: hand-rolled JSON with basic escaping
        if [[ -z "$line" ]]; then
            local ts esc_file esc_subtask esc_reason
            ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
            esc_file=$(_tdd_log_jsonesc "${3:-}")
            esc_reason=$(_tdd_log_jsonesc "${2:-}")
            esc_subtask=$(_tdd_log_jsonesc "${4:-}")
            local tdd_bool="false"
            [[ "${5:-}" == "true" ]] && tdd_bool="true"
            line=$(printf '{"ts":"%s","tool":"%s","file":"%s","decision":"%s","reason":"%s","subtask":"%s","tdd_required":%s}' \
                "$ts" "${TDD_HOOK_TOOL:-unknown}" "$esc_file" "${1:-}" "$esc_reason" "$esc_subtask" "$tdd_bool")
        fi

        printf '%s\n' "$line" >> "$log" 2>/dev/null
    } 2>/dev/null
    return 0
}

# Minimal JSON string escaper for the fallback path. Escapes \ and ", strips
# control characters. Not RFC-perfect but safe for the field values we log.
_tdd_log_jsonesc() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    # Strip raw control chars (newline, tab, CR) by replacing with space
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    printf '%s' "$s"
}

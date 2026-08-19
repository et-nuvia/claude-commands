#!/usr/bin/env bash
# track-command-hook.sh — automatic command lifecycle tracking.
#
# Replaces the "run track-command.sh as your first action / when complete"
# boilerplate that every command doc used to carry. That contract cost two
# LLM tool calls per invocation and was unreliable in practice: measured over
# the transcript history, ~35% of `--event complete` calls never happened
# (long sessions forget), and the token/cost values were model guesses —
# the model cannot know its own usage. This hook fires deterministically and
# reads REAL usage from the transcript via lib/transcript-usage.py.
#
# Wiring (settings.json):
#   UserPromptSubmit (async) — a prompt starting with /<command> closes out any
#     active command for this session (complete, with token/cost deltas) and
#     starts tracking the new one.
#   SessionEnd (async) — closes out the active command, if any.
#
# Lifecycle semantics: a command's span runs from its /invocation until the
# NEXT /command or session end. Freeform follow-up prompts inside that span
# are attributed to the active command — that is deliberate: the follow-ups
# are part of doing that command's work.
#
# Never blocks: every path exits 0.

set -uo pipefail

CLAUDE_DIR="${HOME}/.claude"
STATE_DIR="${CLAUDE_DIR}/tracking/active"
TRACK="${CLAUDE_DIR}/scripts/track-command.sh"
USAGE_PY="${CLAUDE_DIR}/scripts/lib/transcript-usage.py"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[[ -n "$SESSION_ID" ]] || exit 0

STATE_FILE="${STATE_DIR}/${SESSION_ID}.json"

usage_snapshot() {
    # {model, total_tokens, cost_estimated} from the transcript; zeros on error.
    python3 "$USAGE_PY" "$TRANSCRIPT" 2>/dev/null \
        | jq -c '{model, total_tokens, cost_estimated}' 2>/dev/null \
        || echo '{"model":"","total_tokens":0,"cost_estimated":0}'
}

close_active() {
    [[ -f "$STATE_FILE" ]] || return 0
    local prev now cmd model tokens cost
    prev=$(cat "$STATE_FILE" 2>/dev/null) || { rm -f "$STATE_FILE"; return 0; }
    now=$(usage_snapshot)

    cmd=$(printf '%s' "$prev" | jq -r '.command // empty')
    rm -f "$STATE_FILE"
    [[ -n "$cmd" ]] || return 0

    model=$(printf '%s' "$now" | jq -r '.model // "unknown"')
    tokens=$(jq -n --argjson a "$prev" --argjson b "$now" \
        '(($b.total_tokens // 0) - ($a.snapshot.total_tokens // 0)) | if . < 0 then ($b.total_tokens // 0) else . end | floor')
    cost=$(jq -n --argjson a "$prev" --argjson b "$now" \
        '(($b.cost_estimated // 0) - ($a.snapshot.cost_estimated // 0)) | if . < 0 then ($b.cost_estimated // 0) else . end | (. * 10000 | floor) / 10000')

    "$TRACK" --command "$cmd" --event complete \
        --model "${model:-unknown}" --tokens "$tokens" --cost "$cost" \
        >/dev/null 2>&1
}

start_command() {
    local cmd="$1" snap
    snap=$(usage_snapshot)
    jq -n --arg cmd "$cmd" --arg ts "$(date -Iseconds)" --argjson snapshot "$snap" \
        '{command:$cmd, started_at:$ts, snapshot:$snapshot}' > "$STATE_FILE" 2>/dev/null
    "$TRACK" --command "$cmd" --event start >/dev/null 2>&1
}

case "$EVENT" in
    UserPromptSubmit)
        PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
        # Match a typed slash command ("/task-continue all") or an expanded one
        # ("<command-name>/task-continue</command-name>").
        CMD=""
        if [[ "$PROMPT" =~ ^[[:space:]]*/([A-Za-z0-9][A-Za-z0-9_:-]*) ]]; then
            CMD="${BASH_REMATCH[1]}"
        elif [[ "$PROMPT" =~ \<command-name\>/?([A-Za-z0-9][A-Za-z0-9_:-]*)\</command-name\> ]]; then
            CMD="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$CMD" ]]; then
            close_active
            start_command "$CMD"
        fi
        ;;
    SessionEnd)
        close_active
        ;;
esac

exit 0

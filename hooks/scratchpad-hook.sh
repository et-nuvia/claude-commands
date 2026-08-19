#!/usr/bin/env bash
# scratchpad-hook.sh — bridges the scratchpad tier to Claude Code's context lifecycle.
#
# Implements the compaction-survival half of the "Wiki-Backed Tiered Agent Memory"
# decision: pointers survive compaction even though note bodies do not.
#
# Two events dispatch through this one script (by hook_event_name on stdin JSON):
#
#   SessionStart  — always records the live session id to <root>/.current-session so
#                   scratchpad.sh writes land in the right dir. When source is "compact"
#                   or "resume" and a manifest exists, re-injects the manifest as
#                   additionalContext so scratchpad pointers survive into fresh context.
#                   MUST be registered SYNCHRONOUSLY (no "async": true) — async stdout is
#                   not injected into context.
#
#   PreCompact    — read-only (PreCompact cannot inject). Snapshots the current manifest
#                   to MANIFEST.precompact.md as a safety net right before compaction.
#
# Fails open: any error exits 0 so it never blocks a session.

set -uo pipefail

ROOT="${SCRATCHPAD_ROOT:-${HOME}/.claude/scratchpad}"
mkdir -p "${ROOT}" 2>/dev/null || true

payload="$(cat)"
event="$(printf '%s' "${payload}" | jq -r '.hook_event_name // empty' 2>/dev/null)"
session="$(printf '%s' "${payload}" | jq -r '.session_id // empty' 2>/dev/null)"
source="$(printf '%s' "${payload}" | jq -r '.source // empty' 2>/dev/null)"

[[ -n "${session}" ]] || exit 0
sdir="${ROOT}/${session}"
manifest="${sdir}/MANIFEST.md"

case "${event}" in
  SessionStart)
    # Record the live session id so scratchpad.sh writes hit the same dir.
    printf '%s\n' "${session}" > "${ROOT}/.current-session" 2>/dev/null || true

    # Only re-inject when continuing prior work and there is something to carry.
    case "${source}" in
      compact|resume) ;;
      *) exit 0 ;;
    esac
    [[ -s "${manifest}" ]] || exit 0

    # Cap the injection: the manifest is copied whole into additionalContext, so an
    # unbounded manifest is the one hook cost that scales with session length. Keep
    # the most recent entries (later lines = later notes) and point at the rest.
    max_lines=40
    total_lines="$(wc -l < "${manifest}" | tr -d ' ')"
    if [[ "${total_lines}" -gt "${max_lines}" ]]; then
      omitted=$(( total_lines - max_lines ))
      body="[${omitted} older entries omitted — run ~/.claude/scripts/scratchpad.sh list for the full manifest]
$(tail -n "${max_lines}" "${manifest}")"
    else
      body="$(cat "${manifest}")"
    fi
    ctx="Scratchpad pointers preserved across ${source} (session ${session}). These are one-line summaries of details offloaded from context during this session; recall the full note on demand with: ~/.claude/scripts/scratchpad.sh recall --id <id>

${body}"

    # jq builds valid JSON regardless of content (quotes/newlines safe).
    jq -n --arg c "${ctx}" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
    exit 0
    ;;

  PreCompact)
    # Safety net: freeze a copy of the manifest at compaction time.
    [[ -s "${manifest}" ]] && cp "${manifest}" "${sdir}/MANIFEST.precompact.md" 2>/dev/null
    exit 0
    ;;

  *)
    exit 0
    ;;
esac

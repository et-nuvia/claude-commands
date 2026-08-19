#!/usr/bin/env bash
# context-guard.sh — PostToolUse hook that protects the context window.
#
# Two guards, dispatched by tool_name:
#
#   Read — re-read enforcement. CLAUDE.md's budget ("a file read 3+ times in a
#     session → STOP and ask why") had no enforcement. This tracks Read paths per
#     session and, from the 3rd read of the same file on, injects a one-line
#     additionalContext warning telling the model to use retained knowledge or
#     scratchpad recall instead. Warning only — never blocks.
#
#   Bash — verbose-success trimming. A successful command that prints a huge
#     payload (a passing test run, a chatty install) rides in context for the rest
#     of the session. If stdout exceeds THRESHOLD and the command produced no
#     stderr, replace the middle with a marker via updatedToolOutput, keeping head
#     and tail. Failures are NEVER touched: any stderr, or output that looks like
#     an error/JSON document, passes through verbatim — evidence preservation
#     (CLAUDE.md Command Hygiene) outranks token savings.
#
# Fails open: every path exits 0 with no output on any error.

set -uo pipefail

INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
session=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[[ -n "$tool" && -n "$session" ]] || exit 0

case "$tool" in
  Read)
    fpath=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [[ -n "$fpath" ]] || exit 0

    state_dir="${HOME}/.claude/tracking/reads"
    mkdir -p "$state_dir" 2>/dev/null || exit 0
    state="${state_dir}/${session}.txt"

    printf '%s\n' "$fpath" >> "$state" 2>/dev/null || exit 0
    count=$(grep -cxF "$fpath" "$state" 2>/dev/null) || exit 0

    if [[ "$count" -ge 3 ]]; then
      msg="context-guard: this is read #${count} of ${fpath} this session (budget: 3). Unless the file changed since the last read, use what you already know, project-context.sh for structure, or scratchpad recall — repeated reads duplicate the file in context."
      jq -n --arg m "$msg" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null
    fi
    exit 0
    ;;

  Bash)
    THRESHOLD=15000   # chars; ~4k tokens. Below this, trimming isn't worth it.
    KEEP=3000         # chars kept from each end.

    stderr_out=$(printf '%s' "$INPUT" | jq -r '.tool_response.stderr // empty' 2>/dev/null)
    [[ -z "$stderr_out" ]] || exit 0

    stdout_out=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null)
    [[ -n "$stdout_out" ]] || exit 0
    size=${#stdout_out}
    [[ "$size" -gt "$THRESHOLD" ]] || exit 0

    # Never trim structured or failure-shaped output: the project's scripts emit
    # one JSON/TOON document that must stay intact, and error text is evidence.
    first_char="${stdout_out:0:1}"
    [[ "$first_char" == "{" || "$first_char" == "[" ]] && exit 0
    if printf '%s' "$stdout_out" | grep -qiE '(^|[^a-z])(error|fail(ed|ure)?|traceback|exception|fatal)' 2>/dev/null; then
      exit 0
    fi

    omitted=$(( size - KEEP - KEEP ))
    trimmed="${stdout_out:0:$KEEP}
[... context-guard trimmed ${omitted} chars of verbose successful output; re-run the command if the middle is needed ...]
${stdout_out: -$KEEP}"
    jq -n --arg o "$trimmed" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedToolOutput:$o}}' 2>/dev/null
    exit 0
    ;;

  *)
    exit 0
    ;;
esac

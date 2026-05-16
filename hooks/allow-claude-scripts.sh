#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: auto-allow any Bash command that invokes a script
# from ~/.claude/scripts/, regardless of how the AI quotes the path.
#
# Solves: intermittent permission prompts caused by the AI sometimes
# wrapping script paths in single or double quotes, which breaks the
# literal prefix matching in settings.local.json.

INPUT=$(cat)

# Extract the command string from the tool input JSON
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Strip all quotes from the command for matching purposes
CLEAN=$(echo "$COMMAND" | tr -d "'" | tr -d '"')

# Check if the cleaned command references our scripts directory
if echo "$CLEAN" | grep -qE "(^|[;&|[:space:]])~/.claude/scripts/" || \
   echo "$CLEAN" | grep -qE "(^|[;&|[:space:]])/Users/[^/]+/.claude/scripts/"; then
  # Auto-allow — must use the exact hookSpecificOutput format
  cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "~/.claude/scripts/ invocation auto-allowed by hook"
  }
}
EOF
  exit 0
fi

# Not a script invocation — exit 0 with no output = fall through to normal rules
exit 0

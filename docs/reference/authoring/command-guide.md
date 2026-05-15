# Command Authoring Guide

## Pattern: Smart Scripts, Simple Commands

Commands are **workflow descriptions** for the LLM agent. Scripts contain all logic.

## Command Template (50-100 lines)

```markdown
---
name: command-name
description: One-line description
user_invocable: true
---

Brief role description.

## Execute

\```bash
RESULT=$(~/.claude/scripts/command-name.sh --json --full [args])
\```

Script automatically:
- What it detects/gathers/validates
- What it handles transparently

## Response Handling

Based on `next_action`:

**`display_summary`** — Success
- What to show the user

**`fix_error`** — Error
- Debug: `~/.claude/scripts/command-name.sh --raw --full`

## Section Flags

\```bash
~/.claude/scripts/command-name.sh --json --section1   # Description
~/.claude/scripts/command-name.sh --json --section2   # Description
\```

## Debugging

\```bash
~/.claude/scripts/command-name.sh --raw --full
\```
```

## Rules

1. **≤150 lines** total
2. **≤3 bash blocks** (execute, section flags, debug)
3. **Zero jq calls** — script handles all JSON
4. **Zero case statements** — use `next_action` prose instead
5. **No inline JSON parsing** — describe actions in prose
6. **Response handling by `next_action`** — not raw status codes

## Anti-Patterns (Don't)

- Extracting JSON fields with jq in the command
- Case statements dispatching on status
- Multi-step bash blocks with error handling
- Duplicating script logic in the command
- Verbose examples showing expected JSON output

## Good Patterns (Do)

- One execute block, one debug block
- Response handling as prose keyed on `next_action`
- Section flags listed for resumption after failures
- Brief description of what the script handles automatically

## See Also

- [Script Authoring Guide](script-authoring-guide.md) — how to write the companion script
- [Command Template](../templates/command-template.md) — copy-paste starter

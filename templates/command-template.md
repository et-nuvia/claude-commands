---
name: {command-name}
description: {One-line description}
user_invocable: true
---

{Brief role description.}

## Execute

```bash
RESULT=$(~/.claude/scripts/{command-name}.sh --json --full [args])
```

Script automatically:
- Reads PROJECT.yaml for configuration
- {What it detects/gathers/validates}
- {What it handles transparently}

## Response Handling

Based on `next_action`:

**`display_summary`** — Success
- {What to show the user}

**`confirm_action`** — Needs user decision
- {What to present, what confirmation means}

**`fix_error`** — Error occurred
- Show `message` to user
- Debug: `~/.claude/scripts/{command-name}.sh --raw --full`

**`{domain_action}`** — {What this means}
- {What the LLM should do}

## Section Flags

```bash
~/.claude/scripts/{command-name}.sh --json --section1   # {Description}
~/.claude/scripts/{command-name}.sh --json --section2   # {Description}
```

## Debugging

```bash
~/.claude/scripts/{command-name}.sh --raw --full
```

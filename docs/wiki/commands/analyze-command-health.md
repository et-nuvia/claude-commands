---
command: analyze-command-health
group: audit
backing_script: ~/.claude/scripts/analyze-command-health.sh
mutates: []
runtime: ~30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /analyze-command-health

Finds which of your own commands and scripts are worth improving, from
evidence in the transcripts — which ones fail, retry, or run long.

---

## When to use it

- Deciding where to spend effort improving the tooling itself
- After a stretch of work that felt slower than it should have
- Before rewriting a command on instinct alone

## Usage

```bash
/analyze-command-health
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | `--command <name>` to scope to one, `--since <date>` to bound the window. |

## Backing script

**Script**: `~/.claude/scripts/analyze-command-health.sh`

```bash
~/.claude/scripts/analyze-command-health.sh --since 2026-07-01
~/.claude/scripts/analyze-command-health.sh --command task-continue
~/.claude/scripts/analyze-command-health.sh --raw --since 2026-07-01
```

## How it works

Mines the transcript archive for each command's invocations and outcomes,
then ranks by the signals that indicate friction: failure rate, retries,
runtime, and follow-up corrections.

## Notes & gotchas

- Depends on transcript history, so a fresh install has nothing to
  analyze.
- Ranks by evidence, which means a command you dislike but that always
  works will score fine — that is the correction it exists to provide.

---

**See also:** [`/analyze-conversations`](analyze-conversations.md) · [`/analyze-task-lifecycle`](analyze-task-lifecycle.md)

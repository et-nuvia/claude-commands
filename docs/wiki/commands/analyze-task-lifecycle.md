---
command: analyze-task-lifecycle
group: audit
backing_script: ~/.claude/scripts/analyze-task-lifecycle.py
mutates: []
runtime: ~1min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /analyze-task-lifecycle

Mines every transcript for how your task lifecycle actually runs, and
recommends where a hook could advance it automatically instead of you
driving each step by hand.

---

## When to use it

- The lifecycle feels like more manual steps than it should be
- Deciding which transitions are worth automating
- Before adding hooks on a hunch

## Usage

```bash
/analyze-task-lifecycle
```

## Arguments

None — invoke with no input.

## Backing script

**Script**: `~/.claude/scripts/analyze-task-lifecycle.py`

```bash
~/.claude/scripts/analyze-task-lifecycle.py --json
```

## How it works

Reconstructs the real command sequences from transcripts, finds the
transitions you perform manually every time, and proposes a hook-driven
auto-advance design for the ones that are consistently mechanical.

## Notes & gotchas

- Recommends automation for transitions that are *already* deterministic.
  A step where you routinely make a judgement call is a step to keep.
- Depends on transcript history.

---

**See also:** [`/analyze-command-health`](analyze-command-health.md) · [Hooks](09-hooks)

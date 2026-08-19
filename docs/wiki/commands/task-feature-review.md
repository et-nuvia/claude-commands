---
command: task-feature-review
group: task-lifecycle
backing_script: ~/.claude/scripts/feature-review.sh
mutates: [files, git]
runtime: ~3min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: required
project_knowledge_sections:
  - Domain Workflows
  - Business Rules
---

# /task-feature-review

Compares a task's implementation against PROJECT-KNOWLEDGE.md to assess
completeness, goal alignment, and functional integrity, and files an
**FRV** document alongside the task's other artifacts.

> **Config:** PROJECT-KNOWLEDGE.md **required** — it is the specification
> this review compares against. Without it there is nothing to measure
> alignment with.

---

## When to use it

- A task is implemented and you want it checked against intent, not just
  correctness
- Before close, when the task changed documented behaviour

## Usage

```bash
/task-feature-review
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A Task ID. Falls back to `.current-task`. |

## Backing script

**Script**: `~/.claude/scripts/feature-review.sh`

```bash
~/.claude/scripts/feature-review.sh --full
~/.claude/scripts/feature-review.sh --raw --full   # debug
```

Section flags let a long review resume rather than restart.

## How it works

1. **Script pass** — resolves the task, its diff, and the
   PROJECT-KNOWLEDGE sections that apply.
2. **Assess** completeness against stated intent, goal alignment, and
   functional integrity.
3. **Write the FRV** and commit it with the task's documents.

## Notes & gotchas

- Distinct from [`/feature-review`](feature-review.md), which is a
  general quality read on any feature and needs no task context.
- "Complete" here means *against the documented goal*, so a task that
  passes its tests can still come back incomplete — that is the point.

---

**See also:** [`/feature-review`](feature-review.md) · [`/task-code-review`](task-code-review.md) · [`/task-post-work`](task-post-work.md)

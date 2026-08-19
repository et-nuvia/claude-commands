---
command: feature-to-task
group: task-lifecycle
backing_script: ~/.claude/scripts/prg-sync.sh
mutates: [files, git, asana, gitlab, github]
runtime: ~2min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /feature-to-task

Converts the recommendations in an analysis document — a feature review,
refactor, performance report, or ARC — into properly scoped TSKs in your
task system.

> **Config:** PROJECT.yaml optional — the task backend decides where the
> TSKs are created.

---

## When to use it

- An analysis document produced more work than you can do now
- Turning an ARC's deferred candidates into tracked follow-ups
- After [`/task-post-work`](task-post-work.md) completes with deferred findings

## Usage

```bash
/feature-to-task <document path>
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Path to the analysis document. Prompts when omitted. |

## Backing script

**Script**: `~/.claude/scripts/prg-sync.sh` (program tracking; no-op for
non-program tasks). The TSKs themselves are created by delegating to
[`/task-capture`](task-capture.md).

## How it works

1. **Select the document** to convert.
2. **Extract recommendations** from it.
3. **Decide granularity** — the critical step. One TSK is one externally
   tracked work item, so recommendations are grouped or split to that
   grain rather than transcribed one-to-one.
4. **Capture** each TSK in turn via `/task-capture`.

Runs on **opus** for the parsing and granularity decisions; the individual
captures use whatever model that command picks.

## Notes & gotchas

- **Granularity is the whole job.** A recommendation list turned into one
  TSK each produces a tracker full of fragments that can't be scheduled;
  turned into one big TSK, it produces something nobody can finish.
- Creates real items in your tracker. Review the proposed split before
  confirming.

---

**See also:** [`/task-capture`](task-capture.md) · [`/task-arch-review`](task-arch-review.md) · [`/feature-review`](feature-review.md)

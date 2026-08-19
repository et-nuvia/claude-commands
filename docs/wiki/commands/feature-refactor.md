---
command: feature-refactor
group: architecture
backing_script: prompt-only
mutates: [files]
runtime: ~5min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - Architecture Decisions
  - Service Map
---

# /feature-refactor

Analyzes a feature for refactoring opportunities that improve stability,
scalability, and simplicity — and says which are worth doing.

> **Config:** PROJECT-KNOWLEDGE.md optional — read first when present, so
> the analysis is grounded in the real domain. The understand graph
> (`.understand/graph.json`) is loaded when it exists and skipped silently
> otherwise.

---

## When to use it

- A feature that works but resists change
- Recurring bugs clustered in one area
- Before building on top of something fragile

## Usage

```bash
/feature-refactor <feature or path>
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Feature name or path. Prompts when omitted. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

0. **Load project knowledge** — `docs/architecture/PROJECT-KNOWLEDGE.md`
   when present, then the structural context from the understand graph.
   Both optional; both skipped silently when absent.
1. **Scope** — identify the feature and the files that constitute it.
2. **Refactoring assessment** — what to change, what it buys, and what it
   risks — including the option of leaving it alone.
3. **Report** — write the review document.
4. **Next steps** — concrete follow-ups, convertible to TSKs via
   [`/feature-to-task`](feature-to-task.md).

## Notes & gotchas

- A refactor with no stated benefit is churn. Every recommendation should
  name what improves and what it costs.
- Read-only — it recommends, it does not refactor. [`/refactor`](refactor.md)
  does the work.

---

**See also:** [`/refactor`](refactor.md) · [`/feature-review`](feature-review.md) · [`/task-arch-review`](task-arch-review.md)

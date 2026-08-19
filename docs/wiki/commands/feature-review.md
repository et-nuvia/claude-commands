---
command: feature-review
group: architecture
backing_script: prompt-only
mutates: [files]
runtime: ~5min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - Domain Workflows
  - Service Map
---

# /feature-review

Reviews one feature for implementation quality — whether it does what it
set out to do, where it is fragile, and what would improve it.

> **Config:** PROJECT-KNOWLEDGE.md optional — read first when present, so
> the analysis is grounded in the real domain. The understand graph
> (`.understand/graph.json`) is loaded when it exists and skipped silently
> otherwise.

---

## When to use it

- A feature is functionally complete and you want a considered read on it
- Before extending something you didn't write
- As input to a refactor or performance decision

## Usage

```bash
/feature-review <feature or path>
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
2. **Technical analysis** — implementation quality, correctness risks, and
   the improvements that would actually pay off.
3. **Report** — write the review document.
4. **Next steps** — concrete follow-ups, convertible to TSKs via
   [`/feature-to-task`](feature-to-task.md).

## Notes & gotchas

- Distinct from [`/task-feature-review`](task-feature-review.md), which is
  task-scoped and produces an FRV document against PROJECT-KNOWLEDGE.
- Read-only.

---

**See also:** [`/feature-refactor`](feature-refactor.md) · [`/feature-performance`](feature-performance.md) · [`/feature-to-task`](feature-to-task.md)

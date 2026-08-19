---
command: feature-performance
group: ops
backing_script: prompt-only
mutates: [files]
runtime: ~5min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - Service Map
  - Integration Flows
---

# /feature-performance

Analyzes a feature for performance bottlenecks, resource usage, and how
it behaves as load grows.

> **Config:** PROJECT-KNOWLEDGE.md optional — read first when present, so
> the analysis is grounded in the real domain. The understand graph
> (`.understand/graph.json`) is loaded when it exists and skipped silently
> otherwise.

---

## When to use it

- A feature that is slow, or expected to get slow
- Before a traffic increase
- To find the actual bottleneck rather than the suspected one

## Usage

```bash
/feature-performance <feature or path>
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
2. **Analysis** — hot paths, N+1 queries, allocation and I/O patterns,
   and what changes at 10× the current load.
3. **Report** — write the review document.
4. **Next steps** — concrete follow-ups, convertible to TSKs via
   [`/feature-to-task`](feature-to-task.md).

## Notes & gotchas

- Static analysis, not measurement. It narrows where to look; confirm with
  real numbers before optimizing — [`/ops-load-test`](ops-load-test.md).
- Read-only.

---

**See also:** [`/ops-load-test`](ops-load-test.md) · [`/ops-scaling`](ops-scaling.md) · [`/feature-refactor`](feature-refactor.md)

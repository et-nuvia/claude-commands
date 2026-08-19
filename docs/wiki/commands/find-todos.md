---
command: find-todos
group: code-quality
backing_script: prompt-only
mutates: []
runtime: ~5s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /find-todos

Locates every TODO, FIXME, HACK, XXX, and NOTE marker in the codebase,
with surrounding code, and groups them by how urgent the marker type
implies they are.

---

## When to use it

- Taking stock before planning a cleanup
- Auditing what a codebase has quietly deferred
- Feeding [`/fix-todos`](fix-todos.md) or [`/todos-to-issues`](todos-to-issues.md)

## Usage

```bash
/find-todos
```

## Arguments

None — invoke with no input.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Searches for `TODO|FIXME|HACK|XXX|NOTE`, case-insensitively, across
source files, showing file and line, the full comment, and the
surrounding code. Findings are grouped by priority:

| Tier | Markers | Meaning |
|---|---|---|
| Critical | `FIXME`, `HACK`, `XXX` | Something is known to be wrong |
| Important | `TODO` | Work intentionally deferred |
| Informational | `NOTE` | Context worth reading, not necessarily acting on |

## Notes & gotchas

- Read-only. Nothing is modified.
- The priority tiers come from the marker the author chose, which is a
  guess about their intent — re-read the comment before trusting the tier.

---

**See also:** [`/fix-todos`](fix-todos.md) · [`/todos-to-issues`](todos-to-issues.md)

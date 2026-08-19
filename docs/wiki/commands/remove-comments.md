---
command: remove-comments
group: code-quality
backing_script: prompt-only
mutates: [files]
runtime: ~30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /remove-comments

Removes comments that merely restate the code, while preserving the ones
that carry information the code cannot.

---

## When to use it

- A file where comment noise is hiding the few comments that matter
- After generated or heavily-scaffolded code lands
- As part of a readability pass

## Usage

```bash
/remove-comments [path]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit to specific files or directories. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Comments are sorted into two piles:

**Removed** — restate what the code does, add nothing beyond the code,
or state the obvious (`// constructor` above a constructor).

**Preserved** — explain *why* something is done, document non-obvious
business logic, or carry a `TODO`/`FIXME`/`HACK` marker.

## Notes & gotchas

- The WHY/WHAT distinction is the whole rule. A comment explaining a
  workaround, a business constraint, or a performance decision stays,
  however obvious the adjacent line looks.
- Review the diff. A comment that reads as redundant to a reader without
  domain context may be the only record of a real constraint.

---

**See also:** [`/make-it-pretty`](make-it-pretty.md) · [`/undo`](undo.md)

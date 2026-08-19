---
command: make-it-pretty
group: code-quality
backing_script: prompt-only
mutates: [files]
runtime: ~1min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /make-it-pretty

Improves readability — naming, nesting, structure — while preserving
exact functionality.

---

## When to use it

- Code that works but is hard to follow
- Before handing a module to someone else
- After a spike, to make prototype code reviewable

## Usage

```bash
/make-it-pretty [path]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit to specific files or directories. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Changes are separated by risk before any are applied:

- **Purely cosmetic** (formatting, obvious renames of locals) — safe.
- **Structural** (extracting functions, flattening nesting) — behaviour
  preserving, but reviewable.
- **Risky** (renaming anything referenced externally, changing implicit
  ordering dependencies) — flagged rather than applied silently.

## Notes & gotchas

- **Functionality is not up for discussion here.** If a readability change
  would alter behaviour, it stops being this command's job — that's a
  refactor, so use [`/refactor`](refactor.md).
- Run [`/test`](test.md) after. "Behaviour preserving" is a claim until
  the suite agrees.
- [`/undo`](undo.md) can roll the pass back.

---

**See also:** [`/remove-comments`](remove-comments.md) · [`/refactor`](refactor.md) · [`/format`](format.md)

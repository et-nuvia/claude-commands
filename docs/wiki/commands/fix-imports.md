---
command: fix-imports
group: code-quality
backing_script: prompt-only
mutates: [files]
runtime: varies
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /fix-imports

Repairs import statements broken by file moves or renames, resuming
across sessions so a large sweep doesn't have to finish in one sitting.

---

## When to use it

- After moving or renaming files and watching imports break
- Following a directory restructure
- Resuming a sweep that was interrupted

## Usage

```bash
/fix-imports [paths or patterns]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Specific paths or import patterns to fix. |
| `resume` / `status` / `new` | No | Continue, report on, or restart the session. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Session state lives in `fix-imports/` in the project root —
`plan.md` holds the broken imports and the fix plan, `state.json` holds
resolution progress. On invocation it resumes from the last import if
`state.json` exists, honours an explicit `resume`/`status`/`new`, and
otherwise scans and creates a new plan.

1. **Analysis** — find every broken import.
2. **Plan** — record them, ordered.
3. **Fix**, updating state as each resolves.

## Notes & gotchas

- The session files are working state, not deliverables. Don't commit
  `fix-imports/`.
- Verify with [`/test`](test.md) — a syntactically valid import can still
  point at the wrong module.

---

**See also:** [`/test`](test.md) · [`/undo`](undo.md)

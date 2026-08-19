---
command: fix-todos
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

# /fix-todos

Resolves TODO comments by actually implementing what they describe,
rather than merely deleting the marker.

---

## When to use it

- A cleanup pass where the deferred work is now worth doing
- After [`/find-todos`](find-todos.md) has shown what's outstanding
- Before a release, to clear known-deferred items

## Usage

```bash
/fix-todos [path or pattern]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit to specific paths or a marker pattern. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Locate** the markers in scope.
2. **Understand** what each one actually asks for, reading the
   surrounding code rather than the comment alone.
3. **Implement** the change, and remove the marker only once the work is done.
4. **Verify** with the test suite.

## Notes & gotchas

- **Deleting a TODO is not resolving it.** If the described work turns
  out to be wrong or obsolete, say so and remove it deliberately — don't
  let a silent deletion look like an implementation.
- Run [`/test`](test.md) afterwards. These are real code changes.

---

**See also:** [`/find-todos`](find-todos.md) · [`/test`](test.md)

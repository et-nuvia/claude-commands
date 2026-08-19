---
command: docs
group: code-quality
backing_script: prompt-only
mutates: [files]
runtime: ~1min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /docs

Keeps project documentation in step with the code by analyzing what
actually changed and updating every doc that references it.

---

## When to use it

- After a change that alters documented behaviour
- Before a release, to catch docs that drifted
- When a README describes a flag or endpoint that no longer exists

## Usage

```bash
/docs [path or topic]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit to a path or topic. Defaults to everything the recent diff touched. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Analyze the change** — what behaviour moved, and which documents
   reference it.
2. **Update** each affected document.
3. **Report** what changed and what was deliberately left alone.

## Notes & gotchas

- Documentation that describes intent rather than mechanics usually
  should *not* be regenerated from code. Check the diff before accepting.
- [`/docs-verify`](docs-verify.md) is the read-only counterpart: it
  reports drift without rewriting anything.

---

**See also:** [`/docs-verify`](docs-verify.md) · [`/document-api`](document-api.md)

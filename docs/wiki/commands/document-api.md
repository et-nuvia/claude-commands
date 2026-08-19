---
command: document-api
group: generators
backing_script: prompt-only
mutates: [files]
runtime: ~2min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /document-api

Scans the codebase for API endpoints and produces consistent, complete
reference documentation from what it finds — not from what the existing
docs claim.

> **Templates:** `~/.claude/templates/api-spec.md` and
> `~/.claude/templates/api-summary.md`.

---

## When to use it

- A service whose endpoints have outgrown their documentation
- Onboarding a consumer who needs a reference
- Before publishing or versioning an API

## Usage

```bash
/document-api [scope]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit the scan to a service, router, or path. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Determine scope** — which services or routers are in scope.
2. **Discover** every endpoint by reading the code, not the existing docs.
3. **Document** each against the api-spec template, and roll them up into
   the api-summary.

Runs on **opus** — the analysis is a whole-codebase sweep where a missed
endpoint is an undetectable omission.

## Notes & gotchas

- Generated from the implementation, so it documents what the service
  *does*. Where that diverges from what it *should* do, the divergence is
  the finding — don't paper over it in prose.

---

**See also:** [`/docs`](docs.md) · [`/docs-verify`](docs-verify.md)

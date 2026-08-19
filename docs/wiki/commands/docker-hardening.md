---
command: docker-hardening
group: infra
backing_script: prompt-only
mutates: [files]
runtime: ~1min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /docker-hardening

Applies the project's Docker security baseline to compose services and
Dockerfiles — read-only filesystems, dropped capabilities, resource
limits, non-root execution, and native healthchecks.

---

## When to use it

- A new service before it first ships
- After [`/docker-audit`](docker-audit.md) reports gaps
- Reviewing an inherited compose file

## Usage

```bash
/docker-hardening [service or path]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit to one service or compose file. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Applies the baseline to every compose service and Dockerfile: `read_only:
true` with tmpfs where writes are genuinely needed, all capabilities
dropped and only the required ones added back, no privileged containers,
`no-new-privileges: true`, explicit resource limits, disabled core dumps,
and native healthchecks rather than shell-based ones.

## Notes & gotchas

- **Healthchecks must be native.** A `CMD-SHELL` or `curl` healthcheck
  assumes a shell and a binary that a hardened runtime image does not
  have, so it fails in exactly the environment it was meant to protect.
- Same for entrypoints: a distroless runtime has no shell, so entrypoint
  logic belongs in a real program, not a `.sh`.
- Verify with [`/docker-audit`](docker-audit.md) afterwards.

---

**See also:** [`/docker-audit`](docker-audit.md) · [`/dockerfile-build`](dockerfile-build.md)

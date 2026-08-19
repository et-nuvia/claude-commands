---
command: makefile-optimize
group: project-config
backing_script: ~/.claude/scripts/makefile-optimize.sh
mutates: [files]
runtime: ~30s
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /makefile-optimize

Audits Makefiles against the project standard and applies the fixes —
missing standard targets, missing JSON output support, hand-rolled docker
commands that should be script calls.

---

## When to use it

- An existing Makefile that predates the standard
- After [`/makefile-audit`](makefile-audit.md) reports gaps
- Adding a component Makefile to a hierarchy

## Usage

```bash
/makefile-optimize
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | `--audit` to report only, `--fix` to apply, `--full` for both. |

## Backing script

**Script**: `~/.claude/scripts/makefile-optimize.sh`

```bash
~/.claude/scripts/makefile-optimize.sh --audit   # report only
~/.claude/scripts/makefile-optimize.sh --fix     # apply
~/.claude/scripts/makefile-optimize.sh --full    # both
```

## How it works

Checks the standard targets (`up down test lint format typecheck migrate
build clean` plus the `ci-*` set), the hierarchical root-delegates-to-
component structure, and `FORMAT=json` support for AI callers — then fixes
what it can.

## Notes & gotchas

- `--audit` first. The fixes touch build tooling, and a diff is cheaper to
  review than a broken target is to debug.
- [`/makefile-init`](makefile-init.md) is for projects with no Makefile at
  all; this one upgrades an existing one.

---

**See also:** [`/makefile-audit`](makefile-audit.md) · [`/makefile-init`](makefile-init.md)

---
name: makefile-optimize
description: Audit and upgrade Makefiles against the standard
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


Audit project Makefiles for compliance with the Makefile Standard and apply auto-fixes.

## Workflow

**1. Run audit:**
```bash
~/.claude/scripts/makefile-optimize.sh --audit
```

**2. Handle by next_action:**

| next_action | Response |
|-------------|----------|
| `display_summary` | Score >= 8/10 — report findings, no action needed |
| `fix_before_push` | Auto-fixable issues found — run `--fix` section |
| `confirm_action` | Manual changes needed — describe what to change |

**3. Apply auto-fixes (if needed):**
```bash
~/.claude/scripts/makefile-optimize.sh --fix
```

**4. Full audit + fix in one pass:**
```bash
~/.claude/scripts/makefile-optimize.sh --full
```

## Auto-Fixable Issues

- Missing `FORMAT ?= human`
- Missing `MAKEFLAGS += --no-print-directory`
- Missing `JSON_WRAPPER` variable
- Missing `targets` meta-target

## Manual-Fix Issues

- Adding `ifeq ($(FORMAT),json)` branches to existing targets
- Adding missing standard targets (test, lint, format, etc.)
- Adding `@` prefix to recipe lines
- Adding the `@../scripts/test-image.sh ensure <service>` prelude to docker-backed `test-*`/`lint-*`/`typecheck-*` targets, so the target owns build-if-stale plus image reclaim and callers stop hand-rolling `docker build`/`docker run` per worktree (wiki: `patterns/makefile-hierarchy.md`)

## When to Use

- Before committing Makefile changes
- When onboarding an existing project to the standard
- After running `/makefile-init` to verify compliance


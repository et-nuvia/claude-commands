---
command: find-dead-code
group: code-quality
backing_script: prompt-only
mutates: [files]
runtime: ~5min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /find-dead-code

Finds code nothing reaches, analyzes the risk of removing each piece, and
removes it — behind a mandatory end-to-end test gate.

> ⚠️ **Deletes code.** Every removal is gated on a passing E2E run; do not
> bypass that gate because a unit suite went green.

---

## When to use it

- Before a refactor, to avoid carrying dead weight through it
- Periodic cleanup of a long-lived codebase
- After a feature removal, to catch the remnants

## Usage

```bash
/find-dead-code [path]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Limit the sweep to a path. |

## Backing script

None — the understand graph is queried via
`~/.claude/scripts/understand-explore.sh --json --search` and `--for-task`
when a graph exists.

## How it works

0. **Structural context** — load the understand graph when present.
1. **Discovery** — candidates nothing references.
2. **Context & risk analysis** — why each looks dead, and what would
   break if it isn't. Reflection, dynamic dispatch, and
   string-constructed names all defeat static reachability.
3. **Mandatory testing** — E2E verification before anything is removed.
4. **Report** what was removed and what was left, with reasons.

## Notes & gotchas

- **The E2E gate is not optional.** Static reachability cannot see a
  route resolved from config, a handler registered by name, or a template
  reference. Those are exactly the cases where deletion breaks production
  and no unit test notices.
- Anything with an unclear verdict should be left in place and reported,
  not removed on the balance of probability.
- [`/undo`](undo.md) can roll a pass back.

---

**See also:** [`/understand-impact`](understand-impact.md) · [`/test-e2e`](test-e2e.md) · [`/undo`](undo.md)

---
command: predict-issues
group: audit
backing_script: prompt-only
mutates: []
runtime: ~3min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /predict-issues

Reads recent changes and predicts what is likely to break — before a
deployment rather than after one.

---

## When to use it

- Before deploying a batch of changes
- After a merge that combined several branches
- When a change touches something with a history of surprises

## Usage

```bash
/predict-issues
```

## Arguments

None — invoke with no input. Operates on recent changes.

## Backing script

None — the understand graph is queried via
`~/.claude/scripts/understand-explore.sh --json --search` and `--for-task`
when a graph exists.

## How it works

1. **Load structural context** from the understand graph when available.
2. **Reason about the changes** — what they touch, what depends on those
   things, and which historical failure modes they resemble.
3. **Report** predicted issues with the reasoning attached.

## Notes & gotchas

- Predictions, not findings. Each one is a hypothesis with a stated
  rationale — read the rationale, not the headline.
- Complements [`/deploy-risk`](deploy-risk.md), which scores blast radius
  rather than guessing at failure modes.

---

**See also:** [`/deploy-risk`](deploy-risk.md) · [`/task-risk`](task-risk.md) · [`/understand-impact`](understand-impact.md)

---
command: explain-like-senior
group: code-quality
backing_script: prompt-only
mutates: []
runtime: ~30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /explain-like-senior

Explains code the way a senior engineer would — the reasoning behind the
design, the trade-offs taken, and what will break at scale — rather than
narrating what each line does.

---

## When to use it

- Onboarding onto an unfamiliar subsystem
- Reviewing a design whose rationale isn't written down
- Deciding whether existing complexity is justified

## Usage

```bash
/explain-like-senior [file, function, or concept]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | What to explain. Defaults to the current context. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Reads the code and its neighbours to establish context, then explains at
three levels:

- **Technical** — why this approach over the alternatives, the trade-offs,
  performance implications, maintenance and scalability factors.
- **Business** — how it fits the wider architecture, its effect on users,
  and the constraints (time, cost, scale) that shaped it.
- **Senior-level judgement** — the observations that only come with
  context: what will need refactoring at 10× scale and why, and where
  complexity is genuinely earned.

## Notes & gotchas

- Read-only.
- The judgement calls are inferences from the code, not statements of
  recorded intent. Where the reasoning matters, write it down — that's
  what [`/session-end`](session-end.md) and PROJECT-KNOWLEDGE are for.

---

**See also:** [`/understand`](understand.md) · [`/feature-review`](feature-review.md)

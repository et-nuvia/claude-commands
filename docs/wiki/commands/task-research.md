---
command: task-research
group: task-lifecycle
backing_script: ~/.claude/scripts/task-research.sh
mutates: [files, git]
runtime: ~5s script, 20-60min of phased LLM research
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
requires_project_knowledge: optional
project_knowledge_sections:
  - Service Map
  - Entity Relationships
  - Integration Flows
---

# /task-research

Turns an open question into a defensible, evidence-backed recommendation.
It runs a phased workflow — ground the current state, fix the goal, set
criteria, research in parallel, then debate the options adversarially —
and ends in an **RDM (Research Decision Matrix)** document where every
score traces back to a stated goal and a verified fact.

> **Config:** PROJECT.yaml optional — used to resolve the task.
> PROJECT-KNOWLEDGE.md optional — grounds candidate options in the real
> system rather than a generic one.

---

## When to use it

- Several plausible approaches exist and the choice will be expensive to reverse
- A decision needs to survive someone else asking "why not the other one?"
- A technology, vendor, or pattern selection that outlives the current task

## Usage

```bash
/task-research
```

**Common invocations:**

```bash
/task-research                   # research for the current task
/task-research 999C92            # research for a task without activating it
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A Task ID. Priority: explicit ID → `.current-task` → error. |

## Dependencies

**Project files consumed:**

- `PROJECT.yaml` (PY) — optional
- `PROJECT-KNOWLEDGE.md` (PK) — optional, read when the script reports
  `knowledge_present: true`
- The task's TSK document

## Backing script

**Script**: `~/.claude/scripts/task-research.sh`

**Inputs:** `--task-id`, the `.current-task` file, the TSK document.

**Outputs:** task identity, `knowledge_present`, the resolved RDM document
path and template, any prior checkpoint, and the `next_action` driving the
phase loop.

**Invocation surface:**

```bash
~/.claude/scripts/task-research.sh --full [--task-id <TASK_ID>]
~/.claude/scripts/task-research.sh --load-state --task-id <TASK_ID>   # resume
~/.claude/scripts/task-research.sh --create-doc                        # write the RDM
```

The research is long enough to be interrupted, so **check for a checkpoint
with `--load-state` before starting the phases** — otherwise a resumed
session silently restarts Phase 0.

## How it works

1. **Phase 0 — Establish current state.** Verified facts about where the
   system is *today*. Not assumptions, not recollection. Everything
   downstream is scored against this.
2. **Phase 1 — Nail down the end goal.** One sentence the decision-maker
   would sign. Options are only comparable relative to a fixed goal.
3. **Phase 2 — Criteria & scope.** The weighted axes, agreed before any
   option is examined — so weights can't be reverse-engineered to favour a
   preferred answer.
4. **Phase 3 — Extensive research.** Parallel sub-agents investigate the
   candidates. These stay on **sonnet**: this is bulk fan-out, and the cost
   difference compounds.
5. **Phase 4 — Adversarial debate & matrix.** Pro and con agents argue each
   option, then the results are synthesized into the weighted matrix and a
   recommendation.
6. **Completeness check**, then `--create-doc` writes the RDM.

## Example workflows

### Scenario: choosing between two architectures

```
/task-capture           # the question, as a TSK
/task-research          # RDM: weighted matrix + recommendation
/task-design            # design the winner
/task-plan
```

Use this when the *choice* is the hard part; `/task-design` when the
choice is settled and the shape is the hard part.

### Scenario: resuming after an interruption

```
/task-research 999C92
```

```
checkpoint found: phase 3 of 4 (research)
  goal:      "Cut p99 checkout latency below 400ms without a rewrite"
  criteria:  latency(0.4) risk(0.3) effort(0.2) ops-cost(0.1)
  options:   4 identified, 2 researched
next_action: continue_phase_3
```

## Notes & gotchas

- **Model choice matters here.** The parent orchestration and final
  synthesis run on the deep-reasoning tier; the Phase 3 fan-out stays on
  sonnet. Don't promote the sub-agents — you pay 5× for bulk retrieval.
- Phase 0 is not a formality. Research grounded in an assumed current state
  produces a matrix that scores the wrong system.
- **Relationship to `/task-design`:** research picks *which*; design decides
  *how*. Running design first tends to lock in the option you happened to
  think of first.
- **If it fails:** `--load-state --task-id <id>` shows exactly which phase
  the checkpoint stopped at.

---
command: sprint-plan
group: task-lifecycle
backing_script: ~/.claude/scripts/sprint-plan.sh
mutates: [files, asana]
runtime: ~5min
destructive: false
requires_project_yaml: required
project_yaml_fields: 
  - sprint.goal
  - sprint.capacity_points
  - task_management.asana.sections
  - task_management.asana.custom_fields
requires_project_knowledge: none
project_knowledge_sections: []
---

# /sprint-plan

Plans one two-week sprint: reconciles local work items into the board,
classifies features versus bugs, scores each backlog item for relevance
against the project's direction, and fills 80% of capacity with the
highest-value work.

> **Config:** PROJECT.yaml **required**. Currently **Asana-only** — the
> board must carry the standardized `Current Sprint` / `Bugs` / `Backlog`
> sections. Section and field names resolve from
> `task_management.asana.sections` and `.custom_fields`, the same config
> the lifecycle scripts read.
>
> **Read [`docs/reference/story-points.md`](../../reference/story-points.md)
> before scoring anything.**

---

## When to use it

- Start of a two-week sprint
- Reconciling local work that never made it onto the board
- Rebalancing a backlog that has drifted from the project's direction

## Usage

```bash
/sprint-plan [--goal "<direction>"]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--goal` | No | Override the project direction for this run. Precedence: `--goal` → `sprint.goal_doc` → PROJECT.yaml `sprint.goal`. |

## Backing script

**Script**: `~/.claude/scripts/sprint-plan.sh`

```bash
~/.claude/scripts/sprint-plan.sh --identify
~/.claude/scripts/sprint-plan.sh --inventory --goal "<direction>"
~/.claude/scripts/sprint-plan.sh --select --decisions <file>
~/.claude/scripts/sprint-plan.sh --apply-plan --plan <file>
```

It refuses to run unless you are on `dev` and the board carries the
standard sections. Selection logic lives in `lib/sprint_select.py`.

## How it works

1. **Validate and gather** — confirm branch and board shape, resolve the
   direction.
2. **Inventory** — the live `backlog`, `current_sprint`, and `bugs`, plus
   every work item in `docs/active` and the open worktrees of each repo
   feeding the board. `unmatched` are local items with no board
   counterpart; `in_flight` have an open worktree.
3. **Judge** — reconcile unmatched items, classify feature vs bug, score
   relevance against the direction, and estimate points.
4. **Select and apply** — fill 80% of capacity.

## Notes & gotchas

- **The direction is not optional and must not be invented.** Every
  relevance score depends on it; if `goal.status` is `missing`, ask, then
  offer to persist the answer to `sprint.goal` so later sprints don't
  re-ask.
- **AI effort estimates in practice run 3–5× high** — the median task
  whose plan claimed 18 hours landed in 1–2 active days. Anchor on "the
  typical task is a 3", not on hours.
- The `Bugs` section frequently holds features. Classify honestly: a bug
  fixes behaviour that already should work; a feature changes intended
  behaviour.
- Relevance is only written to the board when `sprint.fields.relevance` is
  configured; otherwise it lives in the summary.
- Declaring a section in both `sprint.sections` and
  `task_management.asana.sections` lets the two silently disagree. Use the
  `sprint.*` form only for a board that genuinely deviates.

---

**See also:** [`/task-capture`](task-capture.md) · [`/task-fetch`](task-fetch.md) · [Story Points](../../reference/story-points.md)

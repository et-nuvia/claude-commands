---
name: sprint-plan
description: Plan a two-week sprint - reconcile local work items into Asana, classify features vs bugs, score backlog relevance against the project direction, and fill 80% of capacity with the highest-value work
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are a sprint planning assistant. You plan one two-week sprint for the current project's Asana board.

**Read `~/.claude/docs/reference/story-points.md` before scoring anything.** It defines the `Score` scale and, critically, records that AI effort estimates in this codebase run **3-5x high**: the median task whose plan claimed 18 hours actually landed in 1-2 active days. Anchor on "the typical task is a 3", not on hours.

## Step 1: Validate and gather

```bash
~/.claude/scripts/sprint-plan.sh --identify
```

This refuses to proceed unless you are on `dev` and the Asana project carries the standardized `Current Sprint` / `Bugs` / `Backlog` sections. It also resolves the **direction/goal**, in precedence order: `--goal` override → `sprint.goal_doc` → `PROJECT.yaml` `sprint.goal`.

**If `goal.status` is `missing`** (status `needs_decision`): ask the user for the project's direction — where this project is going over the next few sprints — then re-run with `--goal "<their answer>"`. Do not invent a direction; every relevance score depends on it. Offer to persist it to `PROJECT.yaml` under `sprint.goal` so future sprints don't re-ask.

Then take inventory:

```bash
~/.claude/scripts/sprint-plan.sh --inventory --goal "<direction>"
```

This returns the live `backlog`, `current_sprint`, and `bugs` contents, every work item found in `docs/active` and the open worktrees of each repo feeding this Asana project, plus `unmatched` — local items with no Asana counterpart — and `in_flight` — items with an open worktree. Read `inventory_file` only if you need the doc paths.

## Step 2: Judge (your work — the script does no thinking here)

Produce a decisions JSON file. Four judgements, in this order:

1. **Match and reconcile.** For each `unmatched` local item, decide whether it is genuinely absent from Asana or is the same work under a different title (compare against the full `backlog`/`bugs`/`current_sprint` lists). Only truly absent items go in `missing` — every unique local task must end up logged in Asana.
2. **Classify** every Asana item and every `missing` item as `feature` or `bug`. Be honest: the `Bugs` section frequently holds features, and those get relocated. A bug fixes behaviour that is already supposed to work; a feature adds or changes intended behaviour.
3. **Score effort** (`points`) on the Fibonacci `Score` scale per the rubric. Use the existing `score` value when a task already has one. Remember the 3-5x correction; reserve 8+ for genuinely substantial work, and treat 15/25 as "should be decomposed".
4. **Score relevance** (`relevance`, 1-10) of each non-bug candidate against the stated direction — 10 = perfectly aligned, moves us directly to the goal state; 1 = do it only if there is time. Bugs are not relevance-scored.

**Carry-over triage — ask the user, do not assume.** For each `in_flight` item and everything currently in `Current Sprint`, ask whether it will be **finished before the sprint starts** or **carries into** it. Carried work consumes the feature budget before any new selection, so guessing here silently overcommits the sprint. Put carried items in `carryover` with `remaining_points` (what is *left*, not the original estimate).

Write the file (all fields optional except as noted; `gid` omitted means "create it"):

```json
{
  "carryover": [{"gid": "...", "name": "...", "remaining_points": 5}],
  "bugs":      [{"gid": "...", "name": "...", "points": 2, "section": "Bugs"}],
  "candidates":[{"gid": "...", "name": "...", "points": 5, "relevance": 8,
                 "classification": "feature", "section": "Backlog"}],
  "missing":   [{"name": "...", "notes": "...", "classification": "feature",
                 "points": 3, "relevance": 6, "repo": "<repo-name>", "source": "<TASK_ID>"}]
}
```

Include `"strict_rank": true` only if the user insists the single highest-rated item must be in the sprint whatever it costs the total.

## Step 3: Compute the fill

```bash
~/.claude/scripts/sprint-plan.sh --select --decisions <file>
```

The script does the arithmetic: carry-over first, then an exact knapsack over the remaining feature budget (`capacity_points` x `feature_ratio`, default 80%) maximising summed relevance — so a 15-point relevance-10 item does not starve a relevance-9 plus relevance-8 pair that fit the same budget. The other 20% stays unassigned as bug and fill headroom.

Present to the user: `capacity` (committed vs budget), `selected` with each item's relevance and points, `carryover`, the top few `deferred` items with their reasons, and every entry in `warnings` — especially when open bug load exceeds the reserve, which means bugs will displace planned work.

## Step 4: Apply (never silently)

```bash
~/.claude/scripts/sprint-plan.sh --apply-plan --plan <plan_file>
```

Dry run by default: it lists the creates, section moves, `Score`, `Sprint`, and relevance writes and changes nothing. **Show the user that list and get explicit approval**, then re-run the same command with `--apply` appended.

Relevance is only written to Asana when `sprint.fields.relevance` is configured; otherwise those actions report `skipped` and the relevance record lives in your summary to the user.

After applying, report `applied`/`failed`/`skipped` counts and surface any `results[].error` verbatim.

## Configuration

All optional — defaults work. In `PROJECT.yaml`:

```yaml
sprint:
  goal: |                      # or goal_doc: docs/DIRECTION.md
    Where this project is heading.
  capacity_points: 45          # Score points per sprint (default 20)
  feature_ratio: 0.8           # planned share; rest is bug/fill reserve
  length_days: 14
  default_points: 3            # assumed when a task has no Score
  repos: [../intake-form, ../forms]   # other repos feeding this Asana project
  fields:
    relevance: Relevance       # omit unless the field exists in Asana
```

**Section and field names have one source of truth: `task_management.asana.sections` and `task_management.asana.custom_fields`** — the same config `asana.sh` and the task lifecycle scripts read. Resolution is `sprint.sections.<key>` → `task_management.asana.sections.<key>.name` → the standard default (`Current Sprint` / `Bugs` / `Backlog`), and likewise `sprint.fields.<key>` → `task_management.asana.custom_fields.<key>.name` → `Score` / `Sprint`. Only set the `sprint.*` form for a board that genuinely deviates; declaring a section in two places lets them silently disagree.

Start from observed throughput — a single active repo often lands near `capacity_points: 45`, while a set of repos sharing one board runs closer to `20`. Correct it after each sprint against what actually completed.

## Response Handling

- **`blocked`** — wrong branch, or the Asana project lacks the sprint sections. Report the fix the script names; do not work around it.
- **`needs_decision`** (identify) — no direction configured. Ask the user, then re-run with `--goal`.
- **`parse_content`** (inventory) — do Step 2.
- **`confirm_action`** (select/apply dry run) — show the plan, get approval, then `--apply`.
- **`fix_error`** — report per [Error Format](docs/reference/ux/error-blocker.md). Debug with `--raw`.

## See also

- [Story Point Scoring](docs/reference/story-points.md) — the shared `Score` rubric and calibration
- `/task-capture` — sets `Score` at creation using the same rubric

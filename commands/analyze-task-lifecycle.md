---
name: analyze-task-lifecycle
description: Mine all Claude Code transcripts for your task lifecycle and recommend a hook-driven auto-advance orchestrator
user_invocable: true
---


If the workflow hits an unrecoverable error:

You are a workflow-automation analyst. Use **model: opus** — this is judgement-heavy synthesis.

The goal: from how the user *actually* runs their task lifecycle across every project,
recommend a **hook-driven auto-advance orchestrator** that chains
capture → start → design → plan → work → review → close → merge-to-dev, pausing at
the real human-verification gates.

## Step 1: Run the analyzer

```bash
~/.claude/scripts/analyze-task-lifecycle.py --json > /tmp/task-lifecycle-analysis.json
```

Optional scoping: `--since YYYY-MM-DD`, `--project <substr>`, `--limit N`.

Read `/tmp/task-lifecycle-analysis.json`. It is deterministic data only — your job is interpretation.

## Step 2: Interpret the data

Work through each section and form conclusions:

- **`lifecycle_usage`** — which commands are actually used vs. ignored. A command in the
  suite with near-zero use is either friction or redundant; call it out.
- **`adoption_funnel`** — drop-off between stages. Where do tasks stop being tracked?
  (Note the `meta.note`: capture→start linkage is intentionally weak because `task-start`
  predates the branch — treat a capture/start gap as a *linkage* problem to automate, not
  proof tasks are abandoned at capture.)
- **`interactive_checkpoints.by_stage`** — THE key signal. `per_invocation` is verification
  density. **High (≥ ~0.8) = a genuine human gate** → the orchestrator must STOP and ask
  there (AskUserQuestion), never silently auto-advance. **Low (< ~0.4) = safe to
  auto-advance** once the prior stage's artifact exists.
- **`ordering.top_transitions` / `backward_transitions_total` / repeated stages** — the real
  state machine, including rework loops (e.g. review → continue → review).
- **`friction`** — `abandoned_tasks_started_not_closed` (tasks that need a nudge/auto-resume),
  `stage_gaps_median` (where latency creeps in — candidates for auto-advance), `errors_by_stage`,
  and `start_to_close` duration.

## Step 3: Produce the recommendation

Write a recommendation document (present inline AND offer to save to
`~/projects/wiki/patterns/task-lifecycle-automation.md` or a DSN doc). Structure it as:

### A. What the data shows
A short, numbers-backed picture of the user's *actual* lifecycle (not the idealized one):
stage adoption, the verification gates, the rework loops, the abandonment/latency hotspots.
Cite the real figures from the JSON.

### B. The state machine
A table of every stage transition with a verdict, derived from the data:

| From → To | Auto-advance? | Why (cite per_invocation / gap / errors) | Gate question (if human) |
|---|---|---|---|

- **Auto-advance**: low interaction density + a detectable completion artifact (a committed
  TSK/PLN/ARC/CRV doc, a PR number, all PLN items checked).
- **Human gate**: high interaction density — design approval, plan approval, arch/code-review
  sign-off, the final close/merge. Spell out the exact question to ask.

### C. The hook-driven design
Map the state machine onto Claude Code hooks (this is the user's chosen form factor). For each,
name the hook event, the trigger condition, and the action:

- **`Stop`** (turn ends) — detect "stage N artifact just landed" (e.g. PLN committed) and
  surface the next step: auto-launch if auto-advance, or prompt with AskUserQuestion if a gate.
- **`PostToolUse`** — watch for the completion signals (git commit of a TSK/PLN/ARC/CRV,
  PR creation) that flip a stage to done.
- **`UserPromptSubmit` / `SessionStart`** — on entering a task worktree, detect current stage
  from the docs/branch (reuse `workflow-progress.sh` + `plan-progress.sh`) and offer to resume —
  directly addressing the abandoned-task finding.
- **`Notification`/`SubagentStop`** as needed.

Include a concrete sketch of the state file the hooks read/write (e.g. extend `.current-task`
or a `.task-state.json`) and how a hook decides auto-advance vs. gate. Reference the existing
deterministic detectors so hooks stay cheap: `workflow-progress.sh` (AUD→ARC→CRV→PR→review),
`plan-progress.sh` (PLN items), and the `find_*` doc helpers.

### D. Interactive gate model
For each human gate, the exact AskUserQuestion prompt + options, and what a "no/changes"
answer routes to (e.g. design rejected → re-run task-design; review failed → task-continue).

### E. Build plan
A phased, low-risk rollout: (1) state file + read-only stage detection hook (suggest-only,
no auto-launch); (2) auto-advance the safe transitions; (3) wire the gates; (4) close+merge.
Note what to verify at each phase before enabling the next.

Keep every claim traceable to a number in the JSON. Where the data is thin (small task N),
say so and mark the recommendation as a hypothesis to confirm as more tasks accrue.


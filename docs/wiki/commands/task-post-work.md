---
command: task-post-work
group: task-lifecycle
backing_script: ~/.claude/scripts/task-post-work.sh
mutates: [files, git, github, gitlab]
runtime: minutes to hours (multi-pass review + fix loop)
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
  - git.platform
requires_project_knowledge: optional
project_knowledge_sections: []
---

# /task-post-work

Runs the whole post-implementation pipeline as one gated sequence — audit,
architecture review, code review, PR creation, PR review — with a
deterministic fix-loop between passes. It doesn't replace the standalone
commands; it chains them and enforces the order and the gates so the run
converges instead of drifting.

> **Config:** PROJECT.yaml optional — the git platform decides where the PR
> is opened; the task backend resolves the task.

---

## When to use it

- Implementation is done and you're heading for a PR
- You want review depth without hand-driving five commands and their gaps
- A previous pipeline blocked and you need to re-enter it

## Usage

```bash
/task-post-work
```

**Common invocations:**

```bash
/task-post-work                  # current task, full ladder from pass 1
/task-post-work 28E853           # a specific task
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A Task ID. Falls back to `.current-task`. |

## Backing script

**Script**: `~/.claude/scripts/task-post-work.sh`

The script is a **state machine**, and it — not the LLM — owns the
sequence and the gating. Each response carries a `next_action` that is
followed exactly, then reported back, until the pipeline completes or
blocks.

**Invocation surface:**

```bash
~/.claude/scripts/task-post-work.sh --start                    # begin (--task-id, --from-pass N)
~/.claude/scripts/task-post-work.sh --record-reviews …         # report normalized findings
~/.claude/scripts/task-post-work.sh --status                   # state, pass history, ledger, last_reviewed_sha
~/.claude/scripts/task-post-work.sh --resume-from-pass N       # re-enter an in-flight/blocked pipeline
~/.claude/scripts/task-post-work.sh --reset                    # clear state, restart clean
~/.claude/scripts/task-post-work.sh --raw --status             # debug
```

> `--start --from-pass N` is for **fresh** pipelines only — it
> re-initializes state and empties the ledger. To re-enter an in-flight or
> blocked pipeline, always use `--resume-from-pass`, or you lose the record
> of what was already accepted.

## How it works

```
STAGE A (pre-PR):  task-audit → task-arch-review → task-code-review   ┐ fix-loop
STAGE B (PR):      create-pr  → review-pr                              ┘ fix-loop
```

**The severity ladder** de-escalates every pass, which is what forces
convergence — an LLM asked to review will always find *something*, so the
bar rises until only real problems can stop the run:

| Pass | Fixes findings at severity | On completion |
|---|---|---|
| 1 | all (critical, high, medium, low) | re-run reviews |
| 2 | critical, high, medium | re-run reviews |
| 3 | critical, high | re-run reviews |
| 4 | critical | re-run reviews |
| 5 | **verify only — fix nothing** | any critical/high left → **BLOCK**, else advance |

Two deviations from running the sub-commands standalone:

- On passes 2+, review is dispatched to the `incremental-reviewer` agent
  instead of the full reviewer. It sees only the delta plus the ledger of
  already-accepted fixes, so it never re-raises a finding pass 1 settled.
- When analysis goes to a subagent, the orchestrator writes the review
  document from the subagent's findings — the artifact is never skipped.

**Severity normalization.** Each sub-command reports in its own vocabulary,
and everything is normalized to `{critical, high, medium, low}` before
being recorded. Failing tests are not a severity — they're a hard gate,
fixed on every pass and blocking at verify.

## Example workflows

### Scenario: standard road to a PR

```
/task-continue          # implementation lands
/task-post-work         # audit → arch → review → fix-loop → PR → PR review
/task-close
```

### Scenario: resuming a blocked pipeline

```
~/.claude/scripts/task-post-work.sh --status
```

```
task: 28E853   stage: pre_pr   pass: 5 (verify only)
status: blocked
  remaining: 1 critical (auth bypass in session refresh)
  ledger: 14 findings → 6 commits
next_action: fix_error
```

Fix the critical by hand, then `--resume-from-pass 5` with `--sha` so the
manual fix is recorded in the ledger.

## Notes & gotchas

- **Never skip or reorder a phase.** Do exactly what `next_action` says —
  the determinism is the whole value.
- **Never fix below the current threshold.** It defeats convergence and can
  loop on nits indefinitely.
- **Read the ledger, not just the green result.** The fix-loop applies
  findings mechanically; a fix that satisfies the letter of a finding while
  missing its intent is exactly what a passing pipeline won't show you.
- A faster ladder is available for experimentation:
  `export TASK_POST_WORK_START_PASS=3` starts every pipeline at pass 3.
  Passes 1–2 mostly churn on low-severity nits the verify pass would have
  deferred anyway. `--from-pass` still overrides per run; unset the
  variable to return to the full ladder.
- Arch candidates below the current threshold can be spawned as follow-up
  TSKs with `/feature-to-task` **after** the pipeline completes — not
  during, which would pause the loop.

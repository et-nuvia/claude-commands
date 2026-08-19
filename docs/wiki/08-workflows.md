# Workflows

Most commands chain together. This page shows the canonical chains and —
critically — **where the human is in the gap** between commands. Claude
runs the steps; the human owns the decisions between them.

> **The pattern.** Each command returns control to you. Read the artifact
> it produced, decide whether to advance, then trigger the next command.
> The gap between commands is not dead time — it's the review step where
> a human catches what Claude missed.

---

## Task Lifecycle

Capture work, plan it, do it, ship it.

```
/task-capture → [HUMAN] → /task-plan → [HUMAN] → /task-start →
  /task-continue (loop) → [HUMAN] → /task-audit → [HUMAN] →
  /task-summary → /task-code-review → /task-close
```

**Commands in this chain:** [`/task-capture`](commands/task-capture.md) ·
[`/task-plan`](commands/task-plan.md) ·
[`/task-start`](commands/task-start.md) ·
[`/task-continue`](commands/task-continue.md) ·
[`/task-audit`](commands/task-audit.md) ·
[`/task-summary`](commands/task-summary.md) ·
[`/task-code-review`](commands/task-code-review.md) ·
[`/task-close`](commands/task-close.md) ·
[`/task-hold`](commands/task-hold.md) ·
[`/task-resume`](commands/task-resume.md)

### Front-loading: know what you're building before you plan

The chain above assumes the work is already understood. Often it isn't,
and planning a misdiagnosed problem is the most expensive mistake in the
lifecycle. Two commands sit between capture and plan for that reason, and
neither is mandatory — pick the one matching what you're missing.

| You don't know… | Command | What it produces |
|---|---|---|
| Why the system behaves this way | [`/task-investigate`](commands/task-investigate.md) | An **INV** doc that traces the actual code path and classifies every finding as `CONFIRMED` or `THEORY` |
| Which of several approaches to take | [`/task-research`](commands/task-research.md) | An **RDM** doc — a weighted decision matrix, built by adversarial pro/con agents rather than one agent's first instinct |
| What the shape of the solution is | [`/task-design`](commands/task-design.md) | A **DSN** doc from an interactive design session |

The discipline that makes `/task-investigate` worth running is its
refusal to guess: "no defect found" is a valid, expected outcome, and a
finding stays labelled `THEORY` until something in the code or in
production proves it. A plan built on a `THEORY` is a plan built on
sand — read the classification column before you plan, not after.

### Back-loading: the gate before the merge

`/task-audit` tells you whether the work is complete. It does not tell
you whether the work is *good*, and a code review run by hand tends to
find whatever the reviewer thought to look for.
[`/task-post-work`](commands/task-post-work.md) runs the whole
post-implementation pipeline as one gated sequence — audit, architecture
review, code review, PR creation, PR review — with a deterministic
fix-loop between passes: findings are applied, then only the *delta* is
re-reviewed, so pass 2 never re-litigates what pass 1 already accepted.

```
/task-continue (loop) → /task-post-work → [HUMAN] → /task-close
                            │
                            └─ audit → arch review → code review
                               → fix-loop → PR → PR review
```

Two of its stages are also useful on their own:

- [`/task-arch-review`](commands/task-arch-review.md) — applies the
  deepening heuristics to a task's diff, so shallow modules, leaky
  seams, and untestable surfaces get caught *before* the merge to `dev`
  rather than in a quarterly architecture sweep.
- [`/task-risk`](commands/task-risk.md) — scores deployment blast radius
  into an **RSK** doc. Distinct from `/deploy-risk`, which scores a
  release; this scores one task's change.

**Where the human still owns the gap.** The fix-loop is deterministic,
not omniscient. It applies findings mechanically and reports a
finding→commit→hunks ledger — read that ledger. A mechanically applied
fix that satisfies the finding while missing its intent is exactly the
failure mode a green pipeline will not show you.

| Gap | What the human does |
|---|---|
| After `/task-capture` | Read the TSK doc. Confirm scope matches what you actually meant. Edit acceptance criteria if Claude misread the request. |
| After `/task-plan` | Read the PLN. Reorder subtasks, drop ones that don't matter, add ones Claude missed. The plan is yours — don't accept it just because it parses. |
| After `/task-start` | Verify the branch/worktree exists and the tracker (Asana/GitLab) shows the task in-progress. If it doesn't, fix the integration before continuing. |
| During `/task-continue` loop | Review each commit before the next iteration. Reject scope creep. If tests pass but feel wrong, say so — Claude won't push back on its own work. |
| After `/task-audit` | Read the AUD doc. If coverage dropped or impacted areas weren't tested, send Claude back to `/task-continue`. Do not advance to summary on a yellow audit. |
| Before `/task-close` | Confirm external systems (Asana, GitLab, GitHub) reflect reality. Close-out updates trackers — if state is wrong now, it'll be wrong forever. |

**Hold/resume gap.** When you `/task-hold`, you own the trigger to resume.
Claude won't notice the external dependency unblocked — set your own
reminder.

---

## Deployment

Risk → stage → smoke/E2E → promote → prod → verify.

```
/deploy-risk → [HUMAN GATE] → /deploy-to-stage → [HUMAN GATE] →
  /deploy-to-prod → [HUMAN VERIFY]
```

**Commands in this chain:** [`/deploy-risk`](commands/deploy-risk.md) ·
[`/deploy-to-stage`](commands/deploy-to-stage.md) ·
[`/deploy-to-prod`](commands/deploy-to-prod.md) ·
[`/plan-mitigate-risks`](commands/plan-mitigate-risks.md) ·
[`/deployment-config`](commands/deployment-config.md)

| Gap | What the human does |
|---|---|
| After `/deploy-risk` | Read the RSK doc. **This is the most important gap.** If risk score is high, run `/plan-mitigate-risks` and address findings before staging. Do not deploy through a high-risk RSK because "it probably won't hit." |
| After `/deploy-to-stage` | Watch the staging environment yourself. Click through the changed feature. Smoke tests pass != feature works. Confirm logs are clean before promoting. |
| Before `/deploy-to-prod` | Re-read the RSK. Confirm the staging window was long enough to catch latent issues. If it's Friday afternoon, ask whether this can wait until Monday. |
| After `/deploy-to-prod` | Watch metrics for the next 15–30 minutes. Auto-rollback catches hard failures; you catch the soft ones (latency creep, error rate edges up, a customer complaint in Slack). |

**Destructive command warning.** `/deploy-to-prod`, `/infra-apply`,
`/infra-destroy`, `/db-restore`, `/db-upgrade` change production state.
The human gate before these commands is non-negotiable, even when Claude
is confident.

---

## Incident Response (RCA)

Page goes off → triage → timeline → analyze → PIR.

```
[INCIDENT] → /rca-triage → [HUMAN] → /rca-timeline → [HUMAN] →
  /rca-analyze → [HUMAN] → /rca-pir
```

**Commands in this chain:** [`/rca-triage`](commands/rca-triage.md) ·
[`/rca-timeline`](commands/rca-timeline.md) ·
[`/rca-analyze`](commands/rca-analyze.md) ·
[`/rca-pir`](commands/rca-pir.md)

| Gap | What the human does |
|---|---|
| During `/rca-triage` | You are the on-call engineer. Claude drafts the INC doc; you confirm severity, scope, and current mitigation. Stop the bleeding first, document second. |
| After `/rca-timeline` | Cross-check the timeline against your own memory and Slack/chat history. Claude reconstructs from logs and will miss human actions that weren't logged. |
| After `/rca-analyze` | Read the 5 Whys. If the root cause feels too convenient ("a developer made a mistake"), push deeper — that's almost never the real root cause. |
| Before `/rca-pir` | Confirm action items have owners and dates. PIRs without owners are decorative. |

---

## Architecture Review

Explore the codebase → grill candidates → explore interfaces.

```
/arch-explore → [HUMAN PICKS] → /arch-grill → [HUMAN DECIDES] →
  /arch-interfaces → [HUMAN COMMITS]
```

**Commands in this chain:** [`/arch-explore`](commands/arch-explore.md) ·
[`/arch-grill`](commands/arch-grill.md) ·
[`/arch-interfaces`](commands/arch-interfaces.md)

| Gap | What the human does |
|---|---|
| After `/arch-explore` | Read the ARC doc. Pick **one** deepening candidate. Claude will surface several; advancing all of them at once produces no decisions. |
| After `/arch-grill` | Read the updated PROJECT-KNOWLEDGE.md and any new ADRs. Confirm the constraints are real and the seam placement matches how the team actually works. |
| After `/arch-interfaces` | The skill produces an opinionated recommendation. Disagree with it if your judgment differs — the recommendation is a starting point, not a verdict. |

---

## Auditing (Scorecards)

Read-only scorecards. Run them, read them, decide what to fix.

```
/{pipeline,docker,makefile,testing,security}-audit → [HUMAN TRIAGES] →
  /review-implement (for chosen findings)
```

**Commands in this chain:** [`/pipeline-audit`](commands/pipeline-audit.md) ·
[`/docker-audit`](commands/docker-audit.md) ·
[`/makefile-audit`](commands/makefile-audit.md) ·
[`/testing-audit`](commands/testing-audit.md) ·
[`/security-audit`](commands/security-audit.md) ·
[`/network-audit`](commands/network-audit.md) ·
[`/review-implement`](commands/review-implement.md)

| Gap | What the human does |
|---|---|
| After any audit | Read the scorecard. Triage findings: critical now, important soon, nice-to-have, won't-fix. Audits without triage just generate guilt. |
| Before `/review-implement` | Hand Claude a *filtered* list of findings. Don't tell it to "fix everything" — you'll get a giant PR that's impossible to review. |

---

## General Principles

1. **Read every artifact Claude produces.** TSK, PLN, RSK, AUD, INC, ARC,
   ADR — they exist so you can review, not so they can pile up unread.
2. **The gap is the review step.** If you find yourself triggering the
   next command without reading the last output, slow down.
3. **Destructive commands need a human gate.** Anything that touches
   production, infrastructure, or external trackers should never auto-chain
   from the previous command.
4. **Claude won't push back on its own work.** Audits, reviews, and
   plans authored by Claude tend to confirm Claude's prior work. You are
   the dissenting voice.
5. **External state drifts.** Trackers, dashboards, and inboxes are
   outside the workflow. If a task is `/task-hold`, you own the resume
   trigger — Claude won't notice the unblock.

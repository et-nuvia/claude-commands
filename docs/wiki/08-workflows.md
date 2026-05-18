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

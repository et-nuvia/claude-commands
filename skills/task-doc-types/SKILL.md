---
name: task-doc-types
description: The V4 task-document naming convention and the full glossary of document type codes (TSK, INC, FIX, PLN, DSN, RCA, CRV, RSK, AUD, VRF, SUM, RDM, and the rest). Load when creating, naming, or identifying a task document.
---

# Task Document Types

## V4 Naming

`<TASK_ID>-<DATETIME>-<TYPE>-description.md`

**Exception — program documents (PRG)** are not task-scoped, so they have no `TASK_ID`:

`PRG-<DATETIME>-<slug>.md`

They also do not live in a month subfolder. A PRG sits at `docs/active/` **root** while active and moves to `docs/completed/` **root** at closeout — a program spans many months, so filing it under the month it started makes it progressively harder to find. Template: `~/.claude/templates/program-PRG.md`.

## Type glossary

| Code | Meaning |
|---|---|
| TSK | task |
| INC | incident report |
| FIX | fix/solution |
| FND | investigation findings |
| INV | investigation report (root-cause output of `/task-investigate`; CONFIRMED vs THEORY) |
| PLN | planning |
| DSN | design (brainstorming decisions) |
| RCA | root cause analysis |
| DEP | deployment guide |
| CRV | code review (quality/security) |
| RSK | risk analysis |
| AUD | audit report |
| VRF | verification report (implementation vs plan, scored) |
| IMP | implementation guide |
| RSC | research (comparative analysis) |
| RDM | research decision matrix (goal/criteria + adversarial pro/con → weighted matrix, output of `/task-research`) |
| LRN | lessons learned |
| SUM | executive summary |
| RSP | outgoing communication |
| UPD | external update received (email/SMS/Cliq) |
| SVC | service documentation |
| RUN | execution run log |
| SCR | script file (.php/.sh/.py) |
| REF | reference/KB article |
| FRV | feature review (completeness/goal alignment) |
| REV | standalone deep-dive review |
| RFA | refactor analysis |
| PRG | program tracker — one initiative spanning many TSKs and months; the single source of truth for cross-task progress. Not task-scoped: see the naming exception above |

## Backend integration

Configure in PROJECT.yaml (`task_management:` — `backend: asana|gitlab`, asana `workspace_id`/`default_project`, gitlab `project_id`).

Auth: Asana `~/.asana-token` · GitLab `~/.secrets/gitlab-token` · GitHub `gh auth`.

## Best practices

1. **Always use Opus** for parsing task descriptions
2. **Document everything** — even simple tasks get a TSK document
3. **Update external systems** — keep Asana/GitLab/GitHub synced
4. **Preserve work on hold** — branch saved for resumption
5. **Move completed docs** — all sequence docs move together to completed/
6. **PRG vs PLN vs TSK** — a PRG tracks an initiative across many TSKs and never gets implemented directly; a TSK is one unit of work; a PLN is that TSK's buildable steps. Keep progress state in the PRG's workstream table (updated at each `/task-close` and `/deploy-to-prod`) and implementation detail in the TSK/PLN. Link between them; never copy.
7. **No deployment steps in plans** — a PLN covers only buildable/testable work (implement, test, verify locally). Deployments and production execution (running scripts/migrations against staging/prod) are **post-close operational steps** handled by `/task-close` then `/deploy-to-stage` → `/deploy-to-prod`, because deploying requires migrating code through branches *after* the task closes. A deploy step inside a PLN can never complete (task-close precedes deployment), leaving the plan permanently stuck. Capture deploy/execution sequences in the TSK **Deployment Plan** section instead. Only include them as plan subtasks if the user explicitly asks.

**See**: [Task Management Guidelines](docs/task-management.md)

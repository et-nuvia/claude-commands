# Program: [Program Name]

- **Program ID**: [PROGRAM_ID]
- **Type**: PRG (Program Tracker — multi-task initiative)
- **Created**: [YYYY-MM-DD HH:MM]
- **Last Updated**: [YYYY-MM-DD HH:MM]
- **Status**: Active | Paused | Complete | Abandoned
- **Owner**: [name]
- **Source document(s)**: [ARC / RDM / AUD / RFA path(s) this program derives from]
- **Location rule**: lives at `docs/active/` **root** (no month subfolder) while Active; moves to `docs/completed/` **root** when every workstream reaches Done or Dropped.

> **What a PRG is.** A PRG tracks one initiative that spans many TSKs over more than one month. It is the single place to answer "where are we, what's left, what did we learn." It is **not** a plan — a PLN belongs to one TSK and covers buildable work. It is **not** a task — a PRG never gets implemented directly.
>
> **What a PRG must never contain**: implementation detail that belongs in a TSK/PLN, or narration that duplicates a child TSK's status log. Link, don't copy.

---

## Goal

[One paragraph. What is true when this program is done that is not true today? State it as an observable outcome, not a list of activities.]

**Definition of done**: [The specific, checkable condition that lets this program move to `docs/completed/`.]

---

## Scope

**In scope**
- [item]

**Out of scope** *(record these explicitly — scope creep is the main failure mode of a long-running program)*
- [item] — *why excluded:* [reason]

---

## Corrections & Supersedes

> Claims in project documentation, `CLAUDE.md`, or memory that this program has proven wrong. Record them here the moment they are found, so no child TSK is spawned to fix a non-existent problem.

| # | Claim (and where it lives) | Reality | Verified by | Doc fixed? |
|---|---|---|---|---|
| 1 | [claim + file/source] | [what is actually true] | [file:line or command] | ☐ |

---

## Shared preconditions (gates)

> Work that must land before specific workstreams may start. A workstream blocked on a gate stays `Blocked` until the gate is `Done`.

| Gate | What it is | Why it gates | Gates which workstreams | Status |
|---|---|---|---|---|
| G1 | [e.g. add missing characterization tests for X] | [e.g. no test proves current behaviour; refactor would be unverifiable] | W2, W6 | ☐ Not started |

---

## Workstreams

> One row per intended TSK. `Status` values: `Not started` → `TSK created` → `In progress` → `In review` → `Merged to dev` → `On staging` → `In production` → `Done`. Plus `Blocked` and `Dropped`.
>
> Keep this table as the single source of truth for progress. Update it at every `/task-close` and every `/deploy-to-prod`.
>
> **The anchors below are load-bearing.** `prg-sync.sh` edits only what sits between them — that is how `/task-start` and `/task-close` update this table automatically without risking a same-shaped table elsewhere in the document. Do not remove them, and keep the `TSK ID` and `Status` column headers spelled exactly as they are; the column *positions* may change freely, since they are located by header name.

<!-- prg:workstreams:begin -->

| W# | Workstream | Source candidate | TSK ID | Status | Gate(s) | Risk | Branch / PR | Notes |
|---|---|---|---|---|---|---|---|---|
| W1 | [name] | [ARC candidate #] | — | Not started | — | Low | — | — |

<!-- prg:workstreams:end -->

### Sequencing rationale

[Why this order. Call out dependencies between workstreams — especially where one shrinks the surface of another.]

---

## Per-workstream detail

> One subsection per workstream. Keep it to the decision-relevant facts; the TSK and its PLN hold the implementation detail.

### W1 — [name]

- **Source**: [ARC candidate #, section link]
- **Why it is worth doing**: [the friction being removed, in one or two sentences]
- **Regression-safety position**: [what existing tests actually protect, and what they do not — distinguish behaviour assertions from mock call-arg assertions]
- **Tests that must be written first**: [list, or "none"]
- **Expected impact**: maintainability [—] · DB [—] · CPU [—] · scalability [—]
- **Traps / must-preserve behaviour**: [intentional-looking-wrong code, deliberate error swallowing, deliberate serialization, distinct scoping modes that must not be unified]
- **Verification method**: [how we will know functionality did not change — specific commands, specific E2E specs]

---

## Verification ledger

> Filled in as workstreams complete. This is the evidence that the program did not change behaviour. "Tests pass" is not evidence unless the tests actually covered the changed path.

| W# | Unit result | E2E result | Staging verified | Production verified | Behaviour change? | Evidence |
|---|---|---|---|---|---|---|
| W1 | — | — | — | — | — | — |

---

## Metrics baseline

> Capture **before** any workstream lands, so the program's claimed impact is measurable rather than asserted. Re-measure after.

| Metric | Baseline | Measured on | Target | Actual after | Notes |
|---|---|---|---|---|---|
| [e.g. queries to delete a 5-record group] | [13] | [YYYY-MM-DD] | [~4] | — | — |

---

## Decision log

> Decisions that change the shape of the program. Append-only — never edit or delete a row; supersede it with a new one.

| Date | Decision | Rationale | Supersedes |
|---|---|---|---|
| [YYYY-MM-DD] | [what was decided] | [why] | — |

---

## Risk register

| # | Risk | Likelihood | Impact | Mitigation | Status |
|---|---|---|---|---|---|
| R1 | [risk] | Low/Med/High | Low/Med/High | [mitigation] | Open |

---

## Deferred / dropped

> Things consciously not done, with the reason. Prevents rediscovering and re-litigating them later.

| Item | Reason | Revisit when |
|---|---|---|
| [item] | [reason] | [condition, or "not planned"] |

---

## Lessons learned

> Append as you go, not at the end. Anything cross-project belongs in the wiki (`~/projects/wiki/`); anything project-durable belongs in memory or `PROJECT-KNOWLEDGE.md`. Note here where it was promoted to.

- [lesson] → promoted to [wiki page / memory / PROJECT-KNOWLEDGE.md section / not promoted]

---

## Status Log

- `[YYYY-MM-DD HH:MM]` — Program created from [source doc].

---

## Closeout checklist

Complete before moving this file to `docs/completed/` (root, no month subfolder):

- [ ] Every workstream is `Done` or `Dropped` (with a reason recorded in *Deferred / dropped*)
- [ ] Verification ledger complete for every `Done` workstream, including production verification
- [ ] Metrics re-measured and *Actual after* filled in
- [ ] All *Corrections & Supersedes* rows have the source document actually fixed (`Doc fixed?` checked)
- [ ] Lessons learned promoted to wiki / memory / PROJECT-KNOWLEDGE.md as appropriate
- [ ] Source document(s) updated to point at this program's outcome
- [ ] `Status` set to `Complete`, final Status Log entry added
- [ ] File moved: `git mv docs/active/PRG-*.md docs/completed/`

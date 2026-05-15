---
name: feature-to-task
description: Convert recommendations from a feature review, refactor, performance, or architecture review (ARC) document into actionable TSKs.
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-to-task" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-to-task" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You orchestrate the conversion of analysis documents into one or more **TSKs** in the user's task system. Use **model: opus** for the parsing/granularity decisions; the individual `/task-capture` calls will use whatever model that command picks.

## Mental model — what a TSK actually is

Before doing anything, internalize this. A TSK in this system is **not** a small one-line item:

- **One TSK = one externally-tracked work item** (Asana task or GitLab issue, created by `/task-capture`)
- **Each TSK has one DSN** (design decisions, resolved + deferred) — created by `/task-design`, refined in place
- **Each TSK has one PLN** (phases + subtasks with `[AC#]` traceability) — created by `/task-plan`
- **Phases and subtasks live in the PLN, not the TSK**. A TSK with 4 phases × 5 subtasks is normal — it does NOT mean 20 TSKs.
- **Acceptance criteria live in the TSK**; PLN subtasks reference them as `[AC1]`, `[AC2]`, etc.

So when you see an analysis document with 20 recommendations, the question is **not** "20 TSKs?" — it's "**what's the right grouping where each group is one externally-tracked work item with its own DSN/PLN?**"

## Step 1: Document selection

Identify the source document. Accepted types:

- **ARC** (Architecture Review) from `/arch-explore` + `/arch-grill` + `/arch-interfaces` — `docs/active/<YYYY-MM>/*-ARC-*.md`
- **FRV / REV** (Feature Review) — completeness/quality reviews
- **RFA** (Refactor Analysis) — refactor plans
- Performance / security audit documents

If the user didn't specify a path, list candidate documents under `docs/active/` and ask.

## Step 2: Recommendation extraction

Read the document end-to-end. Extract the structured list of recommendations:

- **For ARC docs**: each numbered candidate in the **Deepening Candidates** section is a potential work item. Candidates with a populated **Grilled Design** are higher-fidelity (the design decisions are already mapped). The **Recommendation** section may identify a hybrid or selected design.
- **For other docs**: extract the recommendations list as the doc structures them.

Also extract any **cross-cutting / shared infrastructure** items (e.g. "Phase 0: Playwright top-up" applies across multiple candidates). These usually deserve their own TSK so the work isn't duplicated.

## Step 3: Granularity decision (CRITICAL)

This is where most people get this wrong. Default rules:

- **One TSK per ARC candidate** — each Grilled Design becomes one TSK with its own DSN (seeded from the Grilled Design) and PLN (where the prep / grill / refactor phases live as subtasks).
- **Bundle into one TSK when**: candidates are tightly coupled and would land in a single coordinated change (e.g. notification dispatcher + per-domain-bypass fix). One TSK with two AC groups is cleaner than two TSKs with a hard ordering dependency.
- **Separate TSK for shared infra**: a cross-cutting prep phase (test harness, Playwright top-up, observability scaffolding) becomes its own TSK — other TSKs depend on it.
- **Never split a single candidate across multiple TSKs**. Prep, grill, refactor, cutover, cleanup are all PHASES INSIDE THE ONE TSK'S PLN.

Show the user your proposed grouping as a numbered list (e.g. "TSK 1: candidate #2, TSK 2: candidates #3 + #10 bundled, TSK 3: candidate #4, …") with the **rationale for each grouping**. Ask:

> "I propose the following TSK structure. Reply with: **all** (proceed), **edit** (tell me which to merge/split), or **specific list** (e.g. 'just TSK 1 and TSK 3')."

Wait for confirmation before any capture.

## Step 4: Per-TSK capture loop

For each TSK approved in Step 3:

### 4a. Determine shape (direct vs investigation-driven)

- **direct**: the recommendation is concrete enough that the design is largely already specified (most ARC Grilled Designs land here).
- **investigation-driven**: the recommendation requires figuring something out first — measure performance, audit test coverage, profile a code path — before the final design can be made. Cues: the ARC has unresolved questions, a test-posture gap, a "we should measure X before deciding" note, or the Migration shape topic was left open.

This shape will be passed through to `/task-capture` and shows up in how the TSK template is filled (Research Findings pending vs absent).

### 4b. Compose the task description

Format the TSK input as Markdown with these sections (this is what `/task-capture` will parse):

```
# <Candidate name — domain term from PROJECT-KNOWLEDGE.md>

## Problem
<Verbatim from the ARC's Problem field, plus deletion-test verdict.>

## Solution shape
<Verbatim from the ARC's Solution field. If Grilled Design exists, summarize:
seam placement, what sits behind the seam, dependency category, adapters.>

## Acceptance criteria
<3-7 observable outcomes. Examples:
- AC1: All `IXxxRepository` interfaces for reference-data entities are deleted
- AC2: Consuming services inject `Repository<T>` directly via `@InjectRepository`
- AC3: Existing consuming-service specs pass without modification
- AC4: No new test infrastructure (testcontainers, PGLite) is introduced
Each AC must be testable — "code is cleaner" is not an AC.>

## Related ARC
<Absolute path to the ARC doc + candidate number.>

## Notes for /task-design
<Pre-resolved design decisions from the Grilled Design — `/task-design` should
record these as Resolved on first run rather than re-litigating.

Deferred decisions: anything the Grilled Design left open with a trigger.>

## Notes for /task-plan
<Suggested phase structure derived from the Grilled Design's Migration shape
+ any test-prep gaps surfaced by a test-posture audit. Example:
- Phase 1 (test prep): write specs for X, Y before refactor
- Phase 2 (refactor): per-entity strangler migration
- Phase 3 (cleanup): delete dead interfaces
This is a suggestion, not a requirement — /task-plan will do its own breakdown.>
```

### 4c. Call /task-capture

```
/task-capture <the markdown block from 4b>
```

`/task-capture` will:
- Create the Asana/GitLab task (external tracking)
- Reserve a TSK file path with a unique work-item ID
- Write the TSK document with Research Findings = pending (if investigation-driven) or absent (if direct)
- Return the task ID and file path

**Capture only one TSK per `/task-capture` call.** Loop sequentially — do not try to batch.

### 4d. Update the source ARC

After each successful capture, **Edit** the source ARC document to add the TSK back-reference next to the candidate. Example:

```
### 2. Anemic TypeORM-wrapper repositories  →  TSK: E33E6B (Asana: 1209876543210)
```

This is for traceability — future readers of the ARC can find the TSK that materialized each candidate. Use the Edit tool; do not rewrite the whole section.

## Step 5: Summary and handoff

After all TSKs are captured, present a single summary table:

| TSK ID | Title | Shape | Asana/GitLab | Next |
|---|---|---|---|---|
| E33E6B | Anemic repo removal | direct | 1209876… | /task-design or /task-plan |
| ... | ... | ... | ... | ... |

Then suggest the immediate next step for the FIRST TSK the user wants to act on:

- **investigation-driven**: `/task-design <TSK_ID>` — the Grilled Design's resolved decisions become DSN Resolved Decisions; any deferred questions become Deferred Decisions with triggers
- **direct, grilled design exhaustive**: `/task-design <TSK_ID>` is still recommended to formalize the decisions in a DSN (cheap, one pass, walks remaining topics from the DSN template like observability/error-handling/auth that the ARC didn't cover)
- **direct, simple**: can skip `/task-design` and go straight to `/task-plan <TSK_ID>` if all DSN topics are obviously not-applicable. Tell the user this is the exception, not the default.
- Then `/task-start <TSK_ID>` when ready to implement

Do NOT auto-start any task. The user picks which TSK to act on next.

## Investigation-driven specifics

If the test-posture / fitness audit reveals that one or more candidates need significant test scaffolding BEFORE refactor (e.g. critical gap, no real-DB harness, untested 600+ LOC service), encode that as Phase 1 of the TSK's PLN — **don't create a separate "write tests first" TSK** unless the test work is so substantial it's its own externally-tracked deliverable.

The standard pattern:
- TSK's PLN Phase 1: investigation / test prep (subtasks: write spec for X, baseline coverage, Playwright top-up)
- TSK's DSN: Migration shape deferred with trigger "after Phase 1 baseline established"
- TSK's PLN Phase 2: `[ACx] Re-run /task-design to resolve Migration shape using Phase 1 findings`
- TSK's PLN Phase 3+: refactor implementation

This keeps the test work attached to the candidate that needs it, instead of orphaning it.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-to-task" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-opus-4-7`)
- `COMPLEXITY` — typically 3 (multi-file feature orchestration). Bump to 4 if generating 5+ TSKs in one run.
- `TOKENS_ESTIMATED` — rough estimate of context used
- `COST_ESTIMATED` — approximate cost in USD

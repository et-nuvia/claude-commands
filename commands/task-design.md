---
name: task-design
description: Run an interactive design brainstorming session and create a DSN document
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-design" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-design" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are a design thinking assistant. Run an interactive brainstorming session to explore design decisions before implementation planning.

## Step 0: Load Project Knowledge (if available)

Before starting the design session, check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists in the project root. If it does, read it first — it contains domain workflows, entity relationships, service maps, integration flows, and business rules that help you:
- Propose architecturally sound design options (know which services exist and their responsibilities)
- Identify integration impacts (e.g., "this change will need Zoho outbound sync updates")
- Understand entity relationships and FK chains before proposing data model changes
- Reference existing patterns (queue-based sync, follow-up hierarchy, two-stage clearance)
- Avoid designs that violate documented business rules

Use this as background context for the brainstorming — don't dump it on the user, but let it inform the options you propose. Skip if the file doesn't exist.

## Execute

```bash
~/.claude/scripts/task-design.sh --full [--task-id <TASK_ID>]
```

If the user provided a task ID as an argument (e.g., `/task-design 999C92`), pass it via `--task-id`:
```bash
~/.claude/scripts/task-design.sh --full --task-id <TASK_ID>
```

Priority: explicit `--task-id` > `.current-task` file > error. This allows designing a task without making it the active working task.

## Response Handling

Based on `next_action`:

**`create_design`** — No DSN exists, start brainstorming
1. Read the TSK document from `task_doc` to understand requirements
2. Run the **Brainstorming Session** (see below)
3. Create DSN doc: `~/.claude/scripts/task-design.sh --json --create-doc`
4. Fill the template with all approved decisions, write to `dsn_path` using the Write tool
5. Commit: `~/.claude/scripts/task-design.sh --json --commit`

**`resume_design`** — DSN already exists
- Read the existing DSN from `existing_dsn` path
- Ask the user if they want to review/update decisions or proceed to planning
- If updating: modify the DSN, then re-commit

**`fix_error`** — Failed
- Debug: `~/.claude/scripts/task-design.sh --raw --full`

## Brainstorming Session

**The ENTIRE POINT of `/task-design` is producing a DSN where every design question has been addressed.** Each topic must end in one of three states — never silently left blank:

1. **Resolved** — a decision was made. Goes in the Design Decisions section.
2. **Not applicable** — the topic genuinely doesn't apply to this task. Requires a one-line reason.
3. **Deferred** — the user explicitly chose to postpone this decision until more information is available. Requires a **trigger** (what unblocks the decision, e.g., "after Phase 1 investigation produces load data"). Goes in the Deferred Decisions section.

A half-finished design document is worse than no design document — it implies decisions were made when they weren't. But an explicit "deferred until X" is not incomplete — it's a valid, documented plan.

Work through topics **one at a time**. For each topic:
1. Ask the user **one focused question**
2. Propose **2-3 approaches** with trade-offs (pros/cons for each)
3. Wait for the user's choice, an explicit "not applicable", or an explicit deferral
4. Record the outcome and move to the next topic

**Topics — explicitly address every one.** For each, land in one of the three states above. Never silently skip.

- **Architecture**: How should the system be structured? What components/layers?
- **Implementation approach**: Build vs reuse? Which patterns to follow?
- **Data model / schema**: What entities, fields, relationships, constraints?
- **Data flow**: How does data move through the system? What formats/protocols?
- **API / interface**: What endpoints, function signatures, events, contracts?
- **Error handling**: What can go wrong? How should failures be handled?
- **Security & auth**: Who can do what? What's the threat model?
- **Observability**: What needs to be logged, metered, traced, alerted?
- **Testing strategy**: What level of testing? Which test types matter most?
- **Migration / rollout**: Backfill? Feature flag? Ordering with other changes?
- **Trade-offs**: Performance vs simplicity? Flexibility vs speed of delivery?
- **Risks**: What could block or derail this? How to mitigate?

Additional task-specific topics should be added when the TSK/PROJECT-KNOWLEDGE context surfaces them (e.g., a Zoho-touching change needs a "sync strategy" topic). If in doubt, add a topic and ask rather than omit it.

### Recognizing investigation-driven tasks

When the TSK type is `Research` or the user has described the task as "figure out X and then fix it", expect a lot of deferrals — that's the point. The flow is:

1. This design session resolves **investigation decisions** (what to measure, what hypothesis, what success looks like) AND records **implementation decisions as deferred** with triggers pointing at the investigation results.
2. `/task-plan` then generates Phase 1 = investigation subtasks + a "revisit DSN" subtask; later phases = implementation that depends on the refined DSN.
3. After Phase 1 finishes, `/task-design` is re-run on the same DSN to resolve the deferred items with real data.

Do NOT invent a new document type for "investigation results" — the TSK's **Research Findings** section is the home for the data, and the DSN is the home for decisions (whether resolved now or deferred).

**Rules for the session**:
- Keep questions short and specific — not open-ended
- Always present concrete options, not abstract ones
- If the user says "you decide", pick the simplest option, explain why, and **record it as a resolved decision** (not deferred)
- If the user says "defer this" / "we'll decide after we investigate" / "we need data first" — that is an EXPLICIT deferral. Ask for and record the **trigger** (what unblocks the decision) before moving on. Do not invent triggers the user didn't state.
- **No arbitrary question cap.** Cover every applicable topic; "5-7 questions" is a rough floor, not a ceiling.
- **No silent "TBD" or placeholder**. Every topic lands in Resolved, Not applicable, or Deferred-with-trigger.

## Pre-Commit Completeness Check

**Before calling `--create-doc`**, classify every topic into one of the three states and list anything still unclassified. If anything is unclassified, return to the session.

When you believe the session is complete:

1. **Restate every decision** to the user as three numbered lists: "Resolved: (1) ..., (2) ...", "Not applicable: (1) ...", "Deferred (with triggers): (1) <decision> — trigger: <X>".
2. **Explicitly ask: "Is every design question either resolved, explicitly not applicable, or explicitly deferred with a trigger?"** Wait for the user's reply.
3. If the user raises anything new — even a minor detail — treat it as a topic and run the brainstorming loop on it.
4. Only once the user confirms, proceed to `--create-doc` and write the DSN.

When filling the DSN template:
- Every resolved topic goes in Design Decisions
- Every deferred topic goes in Deferred Decisions **with a Trigger line** — this is what `/task-plan` reads to generate investigation subtasks
- If you catch yourself writing "TBD", "we'll decide later" without a trigger, or leaving `[LLM to fill in]` untouched, stop and go back to ask the user before writing

## Re-running on an Existing DSN (Design Refinement)

If `next_action == "resume_design"` the DSN already exists. Read it and classify its current state:

- **Deferred Decisions section non-empty**: the task is in its investigation-driven flow. This is the expected path for research/investigation tasks. Do the following:
  1. Read the TSK's Research Findings section (if populated) and any FND documents for the task
  2. For each deferred decision, check whether the **trigger** has been met (e.g., if trigger says "after Phase 1 investigation", check if Phase 1 is complete and findings are recorded)
  3. List triggered deferrals to the user: "These deferrals are now unblocked: (1) ... (2) ..."
  4. Run the brainstorming loop on each triggered item — propose approaches informed by the investigation data, resolve, and move the item from Deferred Decisions to Design Decisions (via Edit tool, not a new DSN)
  5. Leave un-triggered deferrals in place with a note about what's still pending
  6. Commit the updated DSN with a message like `design(refine): resolve deferred decisions after investigation — TASK_ID`

- **Deferred Decisions section empty and user wants to add topics**: run brainstorming for the new topics, append to Design Decisions, commit.

- **User just wants to review**: show the decisions and exit without edits.

**Never create a second DSN for the same task.** Refine the existing one in place — the Design Decisions section grows as deferred items get resolved.

**Resumable brainstorming (checkpoint pattern)**:

Long brainstorming sessions can be interrupted (context loss, network drop, user stepping away). To make them resumable, save state after each answered topic:

```bash
~/.claude/scripts/task-design.sh --save-state --task-id "$TASK_ID" \
  --decisions '[{"topic":"Architecture","choice":"Event-driven","rationale":"..."},{"topic":"Data flow","choice":"Pull","rationale":"..."}]'
```

At the start of any design session, check for existing state:

```bash
~/.claude/scripts/task-design.sh --load-state --task-id "$TASK_ID"
```

- If `next_action == "resume_brainstorm"`: read the returned `decisions` array, summarize them for the user, and ask whether to continue from where they left off or restart. Pick up at the next topic not yet in the array.
- If `next_action == "create_design"`: no prior state — start fresh.
- The state file is automatically deleted when `--commit` succeeds, so it doesn't linger after the DSN is persisted.
- The state file only persists for the matching task ID — state from a different task is ignored.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-design" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing

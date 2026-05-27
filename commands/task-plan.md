---
name: task-plan
description: Break down features into implementation plan with subtasks and estimates
user_invocable: true
---

You are a technical architect. Your ONLY job is to run the script, then handle its JSON response.

**CRITICAL: Run the script IMMEDIATELY as your first action. Do NOT read the task document, explore the codebase, or analyze requirements beforehand. The script loads requirements and returns them to you. Your first Bash call MUST be the script.**

## Execute

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

Run this as your FIRST action — include the tracking call in the same Bash block:

```bash
~/.claude/scripts/track-command.sh --command "task-plan" --event start
~/.claude/scripts/task-plan.sh --full --source "path-or-url"
```

Parse `RESULT` as JSON → read `next_action` → follow the matching handler below.

## Response Handling

Based on `next_action`:

**`use_opus_model`** — Opus required for analysis
- Script has loaded requirements from `requirements` field
- **Read `docs/architecture/PROJECT-KNOWLEDGE.md`** (if it exists) — this contains domain workflows, entity relationships, service maps, integration flows, and business rules. Use it to:
  - Identify which services and entities are affected by the feature
  - Understand integration impacts (Zoho sync, AI pipeline, communication follow-ups)
  - Know the correct service responsibilities before exploring code
  - Avoid missing affected systems (e.g., zone status updates, activity events, notifications)
  - This replaces broad codebase exploration — do targeted reads only for implementation details not covered in the doc
- **Load structural context from the Understand graph (after PK, before TSK):** if `.understand/graph.json` exists in the current working directory AND a `task_id` is known (from `requirements.task_id` or the TSK filename), run `~/.claude/scripts/understand-explore.sh --json --for-task <task_id>` to fetch ranked nodes for this task. Include the top results (up to ~20 nodes) in your working context as a bullet list of `{node_id} — {summary}` so that subtask descriptions can cite real file paths and function names instead of generic prose. The PK read gives you the domain frame; this gives you the concrete code surface. **Skip silently** (do not block, do not surface an error) if `.understand/graph.json` is absent, if the script errors, or if `--for-task` returns an empty result set.
- **Read the TSK document** (`requirements.source_data`) — extract ALL requirements (functional, technical, acceptance criteria). Also note: is the **Research Findings** section present and marked "Investigation pending"? If so, this is an investigation-driven task — see next section.
- **Read the DSN document** (if `requirements.dsn_data` is non-null) — extract ALL design decisions from the `## Design Decisions` section AND ALL deferred items from the `## Deferred Decisions` section. Each deferred decision has a `Question`, `Why deferred`, `Trigger to resolve`, and `Candidates under consideration`. The deferred list drives Phase 1 planning (see next section).
- Read PROJECT.yaml for tech stack, components, testing config
- Explore codebase: find related files, existing patterns, affected systems (use targeted searches — the knowledge doc already maps service responsibilities)
- **Coverage check**: Before generating the plan, verify that EVERY TSK requirement, EVERY DSN Design Decision, and EVERY DSN Deferred Decision maps to at least one subtask. Deferred decisions map to investigation + design-refinement subtasks (see next section). Unresolved requirements get flagged by the review step.

**Investigation-driven plans (when DSN has Deferred Decisions OR TSK Research Findings is "Investigation pending")**

Do NOT generate a new document type. Use the existing PLN with an explicit phase structure:

- **Phase 1 — Investigation**: one subtask per deferred decision (or per research question in the TSK). Each subtask's Description names the decision it unblocks and cites the `Trigger to resolve` from the DSN. Typical subtask shapes: "add logging/instrumentation", "run profiler and capture data", "query DB to measure X", "read code path Y and document behavior". The output of Phase 1 is written into the TSK's **Research Findings** section (that's where findings belong — no separate FND document unless the investigation is substantial enough to warrant one).
- **Phase 2 — Design refinement**: a single subtask labeled `[ACx] Re-run /task-design to resolve deferred decisions using Phase 1 findings`. Description explicitly lists which deferred items from the DSN it is expected to resolve. Work Model: opus. TDD: no. This phase edits the existing DSN in place (moves items from Deferred Decisions → Design Decisions) — it does NOT create a new DSN.
- **Phase 3+ — Implementation**: normal implementation subtasks that depend on Phase 2 being complete. These MUST reference the DSN decisions they implement. If an implementation subtask would need to know something only resolved in Phase 2, mark its Dependencies as `Phase 2 complete`.
- **Phase N — Validation**: tests, smoke checks, and verification that the fix actually addresses the investigation's root cause.

If the TSK is fully spec'd (no deferred decisions, Research Findings is absent or populated at capture time), skip the investigation/refinement phases and plan as usual — Phase 1 = Implementation.

**Never duplicate investigation output into the PLN.** Findings live in TSK Research Findings; decisions live in DSN; the PLN just orchestrates when they happen.
- Break into phases, each with subtasks containing ALL of these fields:
  - **Description**: What needs to be done
  - **Files**: Which files to create/modify
  - **Dependencies**: Which subtasks must complete first
  - **Complexity**: XS / S / M / L / XL
  - **Time Estimate**: Hours (e.g., 1h, 2h, 4h, 8h)
  - **Work Model**: Which AI model for implementation (opus / sonnet / haiku)
  - **Test Model**: Which AI model for test writing, if applicable (opus / sonnet / haiku / n/a)
  - **Risks**: Anything that could go wrong
  - **TDD Required**: yes / no — per-task TDD enforcement (no "recommend" — resolve at planning time)
  - **Auto Review**: yes / no — whether to run automatic review after this task
  - **Review Type**: single / two-stage — review depth for this task
  - **Fresh Context**: yes / no — whether to dispatch in isolated subagent
- **Acceptance Criteria Traceability**: Each subtask checkbox MUST include an `[AC#]` tag referencing which TSK acceptance criterion it satisfies. Format: `- [ ] [AC1] Implement the thing`. Multiple tags allowed: `[AC1][AC3]`. If a subtask doesn't map to a specific criterion, use `[ACx]` (infrastructure/support). This enables `plan-progress.sh` to auto-mark TSK criteria when all referencing PLN items are complete.
- Subtasks may have their own subtasks (nested) — each with the same fields and `[AC#]` tags
- Sum time estimates per phase and total

**Model Selection Guidelines:**
- **opus**: Complex logic, architectural decisions, multi-file coordination, security-sensitive code
- **sonnet**: Standard CRUD, hooks, components, straightforward feature work
- **haiku**: Simple wiring, renaming, config changes, search-and-replace style tasks
- **Test model**: Usually one tier below work model (opus work → sonnet tests, sonnet work → haiku tests). Use same tier if tests require complex mocking or architectural understanding.

**`generate_plan`** — Ready to create plan document

**CRITICAL ORDER — write → review → iterate → commit. The plan is only committed AFTER it passes review. Never commit an unreviewed plan.**

1. **Get template + filepath**:
   - If source is a task document with a work item ID (e.g., DE27B2): `~/.claude/scripts/new-doc.sh --type PLN --description "description" --id TASKID --json`
   - If no work item (standalone): `~/.claude/scripts/new-doc.sh --type PLN --description "description" --new --json`

2. **Write the PLN document with concrete metadata in a single pass** (DO NOT COMMIT YET). Response contains `template` and `filepath`. Fill the template and write to `filepath` using the Write tool.

   **CRITICAL: Do NOT leave template placeholders like `[yes/no]`, `[single/two-stage]`, or `[XS/S/M/L/XL]` in the file.** Every subtask must have concrete values when first written — the review step will reject placeholders, forcing a wasted edit pass. Apply the rubric below *while writing*, not after:

   - **L/XL implementation**: `TDD Required: yes`, `Auto Review: yes`, `Review Type: two-stage`, `Fresh Context: yes`
   - **M implementation**: `TDD Required: yes`, `Auto Review: yes`, `Review Type: single`, `Fresh Context: no`
   - **XS/S implementation**: `TDD Required: no`, `Auto Review: no`, `Review Type: single`, `Fresh Context: no`
   - **Research/docs/config**: `TDD Required: no`, `Auto Review: no`, `Review Type: single`, `Fresh Context: no`
   - Use judgment — a typo fix doesn't need TDD, a new API endpoint does

   **Time-estimate caps by complexity** (the reviewer enforces these — split if you exceed):
   - XS ≤ 30m, S ≤ 2h, M ≤ 4h, L ≤ 8h, XL ≤ 16h

   **Completed/audit-baseline tasks** (status already `[x] Complete`): execution-config fields are not enforced and may be omitted; include a `**Status**: Complete (<commit-sha>)` line instead.

3. **TDD Resolution** — After generating the plan, collect all subtasks where `tdd_required` is borderline (e.g., M-complexity tasks that could go either way). Present them to the user in a batch:
   - List each borderline task with its title and complexity
   - Ask: "Convert all to `yes`, all to `no`, or review individually?"
   - If "all yes": set all to `yes`
   - If "all no": set all to `no`
   - If "review": ask for each one individually
   - The final plan MUST only contain `yes` or `no` — never `recommend`

4. **Review BEFORE commit**: `~/.claude/scripts/task-plan.sh --json --review --source "path-to-pln.md"`
   - If `next_action == "fix_plan"`: handle per **`fix_plan`** handler below, then loop back here to re-review.
   - If `next_action == "continue"`: proceed to step 5.

5. **Commit the plan document** — only reached after review passes. Use `~/.claude/scripts/new-doc.sh --commit` or a direct `git add` + `git commit`. The commit message should reference the plan (e.g., `plan(TASKID): implementation plan for <title>`).

Use EnterPlanMode for complex features (10+ tasks) during step 2.

**`fix_plan`** — Plan review found quality issues (called from step 4 above, NOT as a standalone entry)
- Read `issues` array — each has `check`, `task`, `message`, `line`
- Fix each issue in the PLN document using the Edit tool (the PLN is not yet committed, so edits are in-place)
- Return to **`generate_plan`** step 4 to re-run review
- Bypass: add `--skip-review` to skip all checks (discouraged — only for emergency unblocking)

**`continue`** — Plan review passed (or skipped)
- The PLN is validated. Proceed to step 5 (commit) if not yet committed. Otherwise, ready for execution (`/task-continue`).

**`display_summary`** — Requirements loaded (section-only mode)
- Show parsed requirements and source type

**`fix_error`** — Loading failed
- Common: no source provided, file not found
- Provide source: `~/.claude/scripts/task-plan.sh --json --full --source "path/to/task.md"`
- Debug: `~/.claude/scripts/task-plan.sh --raw --full --source "path-or-url"`

## Section Flags

```bash
~/.claude/scripts/task-plan.sh --load --source "path-or-url"
~/.claude/scripts/task-plan.sh --analyze --source "path-or-url"
~/.claude/scripts/task-plan.sh --breakdown --source "path-or-url"
~/.claude/scripts/task-plan.sh --estimate --source "path-or-url"
~/.claude/scripts/task-plan.sh --generate --source "path-or-url"
~/.claude/scripts/task-plan.sh --review --source "path-to-pln-or-task.md"
~/.claude/scripts/task-plan.sh --review --skip-review --source "path.md"
```

## Debugging

```bash
~/.claude/scripts/task-plan.sh --raw --full --source "path-or-url"
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-plan" --event complete \
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

---
name: task-feature-review
description: Create a feature review document for a task following the FRV template
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-feature-review" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-feature-review" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a feature review assistant. Compare the current implementation against PROJECT-KNOWLEDGE.md to assess completeness, goal alignment, and functional integrity.

## Execute

Run this as your FIRST action:

```bash
~/.claude/scripts/feature-review.sh --full
```

## Response Handling

Based on `next_action`:

**`build_project_knowledge`** — PROJECT-KNOWLEDGE.md not found
- Inform the user that feature review requires domain knowledge documentation
- Offer to create `docs/architecture/PROJECT-KNOWLEDGE.md` using the template at `~/.claude/templates/PROJECT-KNOWLEDGE.md`
- Walk through each section interactively (Domain Overview, Core Workflows, Integration Flows, Auth, ERDs, Service Map, Business Rules)
- Once created, re-run: `~/.claude/scripts/feature-review.sh --json --full`

**`analyze_code`** — Implementation context gathered, needs Opus analysis
- Read the `project_knowledge` sections (workflows, business_rules, service_map, integrations)
- Read the task document and plan document (if available)
- For each changed file, compare against:
  - **Goal Alignment**: Does the code fulfill the TSK document's requirements?
  - **Workflow Compliance**: Do changes follow documented Core Workflows?
  - **Business Rule Adherence**: Are documented Business Rules respected?
  - **Service Boundaries**: Are changes in the correct service per Service Responsibility Map?
  - **Integration Impact**: Are affected Integration Flows properly updated?
  - **Mock Data Detection**: Search for hardcoded strings, setTimeout mocks, or JSON stubs
  - **Reference Integrity**: Scan for stale references to changed functions
- Then run: `~/.claude/scripts/feature-review.sh --json --report`

**`generate_report`** — Ready for FRV document generation
- Use `frv_template` as document structure
- Fill with analysis findings from the previous step
- Write to `frv_filepath` using the Write tool
- Present findings to user with next steps:
  1. Fix identified gaps automatically
  2. Create subtasks in PLN for missing pieces
  3. Proceed to `/task-code-review`
- Format per [Completion Format](docs/reference/ux/task-completion.md)

**`fix_error`** — Review failed
- Common: no `.current-task` file, task document not found
- Provide task ID: `~/.claude/scripts/feature-review.sh --json --full --task-id A3F2B9`
- Debug: `~/.claude/scripts/feature-review.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md)

## Section Flags

```bash
~/.claude/scripts/feature-review.sh --identify            # Task identification only
~/.claude/scripts/feature-review.sh --analyze              # Gather implementation context
~/.claude/scripts/feature-review.sh --report               # Generate FRV doc context
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-feature-review" --event complete \
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

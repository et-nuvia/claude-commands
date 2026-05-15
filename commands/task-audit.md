---
name: task-audit
description: Audit task progress - check status, test coverage, and project-wide impact of changes
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-audit" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a task audit assistant. Run comprehensive audit of work done on a task.

## Step 0: Load Project Knowledge (if available)

Before running the audit, check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists in the project root. If it does, read it first — it contains domain workflows, entity relationships, service maps, integration flows, and business rules that significantly improve audit quality:
- **Impact analysis**: Understand which services depend on which (service responsibility map) to identify ripple effects of changes
- **Business rule validation**: Check if changes respect documented invariants (e.g., two-stage clearance, center scoping, Zoho sync rules)
- **Completeness assessment**: Verify all affected integration points are covered (e.g., a patient status change should update Zoho, notifications, activity events)
- **Entity relationship awareness**: Identify if FK chains or cascade rules could be affected by schema changes
- **Communication follow-up hierarchy**: Understand the RecordFollowUp → child entity pattern when auditing communication features

Use this knowledge to enrich the audit findings beyond what the script's automated checks can detect. Skip if the file doesn't exist.

## Execute

```bash
~/.claude/scripts/task-audit.sh --full
```

Script automatically:
- Identifies task from `.current-task` or task ID
- Analyzes commits, files changed, test coverage
- Checks acceptance criteria completion and TODOs
- Calculates audit score and status (excellent/good/fair/needs_work)
- Resolves AUD document filepath and includes AUD template
- Excludes false-negative files from coverage counting: migrations, ORM models, Pydantic schemas, route registrations, type declarations (these are tested indirectly via CRUD/API tests)

## Response Handling

Based on `next_action`:

**`generate_document`** — Audit complete, generate AUD document
1. Use `aud_template` as the document structure
2. Fill every section using the audit data from the JSON (`scores`, `work`, `testing`, `completion`, `raw_data`, `recommendations`)
3. Write the completed document to `aud_filepath` using the Write tool
4. Then display the summary to the user:
   - Show `audit_status` and `scores.overall` (0-100)
   - **excellent** (90+): Ready for `/task-close`
   - **good** (70-89): Address minor items from `recommendations`, re-audit
   - **fair** (50-69): Prioritize: failing tests > missing coverage > incomplete criteria > TODOs
   - **needs_work** (<50): Review plan, prioritize fixes, use `/task-continue`
   - Tell the user the AUD document location
   - Format per [Completion Format](docs/reference/ux/task-completion.md).

**`fix_error`** — Audit failed
- Common: no `.current-task` file, task document not found, no test command
- Provide task ID: `~/.claude/scripts/task-audit.sh --json --full --task-id A3F2B9`
- Debug: `~/.claude/scripts/task-audit.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md).

**`verify_implementation`** — Verification mode (`--verify` flag)
- Script returned PLN document path, changed files, and 100-point scoring rubric
- Read the PLN document to understand all planned tasks
- Read each changed file and verify against the plan
- Score each of 6 categories:
  - **Plan Completeness** (30 pts): Each planned task implemented
  - **Code Quality** (25 pts): Conventions, DRY, error handling, consistency
  - **Test Coverage** (25 pts): TDD pattern, happy + error + edge cases covered
  - **Security** (10 pts): No hardcoded secrets, input validation, injection prevention
  - **Performance** (5 pts): No N+1, missing indexes, O(n^2)
  - **No Regressions** (5 pts): All pre-existing tests pass
- Generate VRF document at `vrf_filepath` using `vrf_template`
- Report: Score/100, verdict (PASS >= 80, PASS WITH ISSUES 70-79, FAIL < 70)
- Format per [Completion Format](docs/reference/ux/task-completion.md)

## Section Flags

Run specific sections for faster feedback:

```bash
~/.claude/scripts/task-audit.sh --test       # Test execution
~/.claude/scripts/task-audit.sh --remaining  # Remaining work
~/.claude/scripts/task-audit.sh --impact     # Impact analysis
~/.claude/scripts/task-audit.sh --verify     # 100-point verification (generates VRF)
~/.claude/scripts/task-audit.sh --re-verify  # Re-run audit after fixing issues; response includes prior AUD path + score so the LLM can report "fixed X, still Y remaining"
```

### Re-audit after fixes

When `/task-audit` returned `fair` or `needs_work` and you've since fixed some issues, use `--re-verify` instead of `--full` to get an incremental view:

- The response includes `prior_aud_path`, `prior_audit_status`, and `prior_overall_score` alongside the fresh scores.
- When writing the new AUD document, cite the delta (e.g., "Previous audit: 58/100 (fair). This audit: 82/100 (good). Fixed: 3 failing tests, 2 TODOs. Remaining: 1 uncovered file.").
- The new AUD document is still written fresh — the prior one is kept for historical record.

## Debugging

```bash
~/.claude/scripts/task-audit.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-audit" --event complete \
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

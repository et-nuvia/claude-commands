---
name: deploy-risk
description: Analyze deployment risks with comprehensive scoring and mitigation options
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "deploy-risk" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "deploy-risk" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a deployment risk analyst. Assess risks before deploying and provide structured analysis with mitigation strategies.

**Model requirement**: Use opus for all analysis — this is complex risk assessment.

## Execute

Ask the user which environment they are deploying to (staging or production), then run:

```bash
~/.claude/scripts/deploy-risk.sh --full --environment staging
```

The script validates prerequisites and gathers automated context. LLM performs the actual risk analysis.

## Handle Response

Read `next_action` from the result:

- `proceed_to_analysis` — Context gathered. Proceed to the LLM analysis tasks below.
- `llm_analyze` — Run the 10-category risk analysis (see Risk Analysis section).
- `llm_score` — Calculate weighted risk score (see Scoring section).
- `llm_generate_document` — Write the RSK document to `document_path` (see Document section).
- `fix_error` — Script error. Report message and details to user.

## Risk Analysis (10 Categories, 0-10 scale)

Analyze each using `git diff main...HEAD` (staging) or `git diff prod...HEAD` (production):

1. **Code Changes** — files, lines, complexity, critical path
2. **Database Migrations** — DROP=9-10, ALTER=6-8, ADD constraint=5-7, ADD nullable=1-2
3. **Dependencies** — CVEs=7-10, major updates=4-6, minor=2-3, patch=1
4. **Configuration** — missing env vars=6-8, secret rotation=4-6, port changes=5-7
5. **Breaking Changes** — removed endpoint=8-10, required field=7-9, removed field=6-8
6. **Rollback Capability** — irreversible=9-10, no down migration=6-7, simple=0-2
7. **Testing Coverage** — no tests=7-9, decreased coverage=5-7
8. **Security** — hardcoded secret=10, SQL injection=10, auth bypass=10, XSS=8-9
9. **Performance** — N+1 queries=6-8, unindexed=7-9
10. **Data Integrity** — destructive migration=9-10, constraint violations=7-9

## Scoring (Weighted)

`Overall = MAX(highest_individual_critical, weighted_score)`

Weights: Security 30%, Data Integrity 25%, Breaking Changes 15%, DB Migrations 10%, Rollback 10%, Code 5%, Dependencies 2.5%, Config 2.5%

Adjustments: Friday +1, Weekend +2, Night +2, no on-call +2, similar past failure +2.

Decision: 9-10=BLOCK, 7-8=CAUTION (mitigate first), 4-6=READY (monitor), 0-3=SAFE.

## Document Generation

When `next_action` is `llm_generate_document`, write RSK document to `document_path` with:
- Executive summary, risk breakdown table, detailed analysis per category
- 2+ mitigation options per risk (effort, effectiveness, steps)
- Deployment readiness assessment, pre-deployment checklist, rollback plan

## Section Flags

```bash
~/.claude/scripts/deploy-risk.sh --gather --environment production
~/.claude/scripts/deploy-risk.sh --analyze --environment production
~/.claude/scripts/deploy-risk.sh --document --environment production
```

## Task-Integrated Mode (V4 RSK document)

When run as part of a task (V4 doc system), pass `--task-id <ID>` so the
risk analysis lands as an RSK-type document under `docs/active/` with
proper V4 naming. To create a fresh task ID at the same time, use `--new`.

```bash
# Existing task — append the RSK doc to its sequence
~/.claude/scripts/deploy-risk.sh --full --environment staging --task-id A3F2B9

# Standalone risk doc but use V4 naming and assign a new task ID
~/.claude/scripts/deploy-risk.sh --full --environment staging --new
```

In V4 mode, the script calls `new-doc.sh` under the hood to resolve the
filepath and return a template the LLM should populate. The
`next_action` returned is `write_document` (the LLM writes to the
resolved `document_path`), rather than `llm_generate_document`.

Without `--task-id` or `--new` (the standalone default), the script
writes to `docs/deployment-risks/YYYY-MM-DD-<env>-<version>.md` — this
is what `deploy-to-stage.sh` and `deploy-to-prod.sh` invoke, so don't
change their flags.

## Debug

```bash
~/.claude/scripts/deploy-risk.sh --raw --analyze --environment staging
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "deploy-risk" --event complete \
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

---
name: testing-audit
description: Audit testing implementation against project standards
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "testing-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "testing-audit" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are a testing infrastructure auditor. Audit a project's test setup against the standards defined in `~/.claude/docs/reference/testing.md` and `~/.claude/docs/reference/makefile.md`.

**Scoring Categories** (weighted):

| Category | Weight | What It Checks |
|----------|--------|----------------|
| Target Hierarchy | 15% | test → test-<service> → test-<service>-<type> cascade |
| JSON Contract | 20% | Runner scripts produce standard JSON, aggregation, error fallback |
| Framework Abstraction | 15% | Callers don't know the framework, FORMAT/human branching |
| Database Seeding | 15% | Seed-once via env var, leaf-only prereq, no file sentinels |
| Data Isolation | 15% | Suite-scoped seed data, self-contained mutations, setup/teardown |
| Coverage Config | 10% | min_coverage in PROJECT.yaml, coverage targets, Jest/pytest config |
| Test Quality | 10% | No .skip, no .only, no console.log in tests |

**Rating Scale**:
- 90-100: EXCELLENT - Production ready
- 70-89: GOOD - Minor improvements needed
- 50-69: FAIR - Several issues to address
- 0-49: NEEDS WORK - Significant gaps

---

## 1. Run Deterministic Scan

```bash
~/.claude/scripts/testing-audit.sh --stage all
```

The script outputs structured JSON to stdout plus writes to `/tmp/testing-audit-result.json`.

---

## 2. Analyze Results (LLM Phase)

After the script completes, read `/tmp/testing-audit-result.json` and provide qualitative analysis.

### Based on `next_action`:

**`display_summary`**: Score is high, few/no issues.
- Present the score card
- Note any warnings as optional improvements
- Suggest running `/makefile-audit` next if not done

**`generate_report_with_fixes`**: Failures found.
- For each **failed** check:
  1. Explain **why** this matters (referencing the standard in `~/.claude/docs/reference/testing.md`)
  2. Provide a **specific fix** with code
  3. Show which file to edit
- For each **warning**: explain the gap and recommend priority
- Group fixes by category

**`generate_report_with_recommendations`**: Mostly passing but several warnings.
- Present the score card
- List warnings grouped by category
- Recommend which to address first

### Category-Specific Analysis

**Target Hierarchy**: Verify the cascade exists: root `test` → `test-<service>` → `test-<service>-<type>`. Check that root targets delegate to service Makefiles, and service Makefiles have leaf targets.

**JSON Contract**: Read the runner scripts and verify they produce the standard fields (`target`, `suites`, `tests`, `passed`, `failed`, `failed_tests`). Check `test-aggregate.sh` wraps children in `targets` array. Verify error fallback (JSON even on framework crash).

**Framework Abstraction**: Verify `ifdef FORMAT` mode calls runner scripts (not Jest/Playwright directly). Verify non-FORMAT mode calls tools directly for human-friendly output. The Makefile should be the only thing that knows which framework runs.

**Database Seeding**: Verify `_TEST_DB_SEEDED` env var pattern. Check that only leaf targets (test-unit, test-e2e) have `_seed-test-db` prerequisite — aggregators (test:) should never seed. Verify `_PASS` forwards the seed state. Flag any file-based sentinels.

**Data Isolation**: Check seed/fixture files for suite-scoped naming. Look for beforeEach/afterEach patterns in test files. Note if mutating tests appear to use shared data.

**Coverage Config**: Verify min_coverage in PROJECT.yaml. Check for coverage targets in Makefiles. Check Jest/pytest config for threshold settings.

**Test Quality**: Flag `.skip`/`xit`/`xdescribe` (skipped tests = useless tests). Flag `.only`/`fdescribe`/`fit` (accidentally excludes other tests). Flag `console.log`/`print()` in test files (noise).

---

## 3. Generate Report

Present findings in this format:

```
Testing Implementation Audit
================================================================

Project: ${PROJECT_NAME}
Date: ${DATE}

Overall Score: ${OVERALL}/100 (${STATUS})

Category Breakdown:
  Target Hierarchy:      ${SCORE}/100  (weight: 15%)
  JSON Contract:         ${SCORE}/100  (weight: 20%)
  Framework Abstraction: ${SCORE}/100  (weight: 15%)
  Database Seeding:      ${SCORE}/100  (weight: 15%)
  Data Isolation:        ${SCORE}/100  (weight: 15%)
  Coverage Config:       ${SCORE}/100  (weight: 10%)
  Test Quality:          ${SCORE}/100  (weight: 10%)

Discovery:
  Components:      ${COMPONENT_LIST}
  Test dirs:       ${TEST_DIR_COUNT}
  Runner scripts:  ${RUNNER_SCRIPT_COUNT}
  Min coverage:    ${MIN_COVERAGE}%

Checks: ${PASSED} passed, ${FAILED} failed, ${WARNINGS} warnings

Top Issues:
${PRIORITIZED_FINDINGS}

Recommendations:
${ACTION_PLAN}
```

---

## 4. Offer Follow-Up Actions

**If score >= 90**:
- "Testing infrastructure looks excellent. Fully aligned with standards."
- Suggest running `/makefile-audit` if not done

**If score 70-89**:
- List specific fixes needed
- Offer to implement fixes now
- "Run `/testing-audit` again after fixes to verify"

**If score 50-69**:
- Show prioritized fix plan
- Start with JSON contract and hierarchy (highest weight)
- Offer to create missing runner scripts

**If score < 50**:
- Provide step-by-step remediation plan
- Start with the basics: target hierarchy and FORMAT branching
- "Consider `/makefile-init` if Makefiles need significant rework"

---

## Important Notes

- **Non-destructive**: Only reads files, makes no changes
- **Repeatable**: Safe to run multiple times
- **PROJECT.yaml required**: Script reads components, databases, and testing config
- **Quick mode**: Use `--quick` on the script to skip seeding and data isolation checks
- **Reference**: `~/.claude/docs/reference/testing.md` and `~/.claude/docs/reference/makefile.md`

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "testing-audit" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` -- the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` -- 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` -- rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` -- approximate cost in USD based on model pricing

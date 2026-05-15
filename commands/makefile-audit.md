---
name: makefile-audit
description: Audit Makefile implementation against project standards
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-audit" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are a Makefile implementation auditor. Audit a project's Makefiles against the standards defined in `~/.claude/docs/reference/makefile.md` and `~/.claude/docs/reference/testing.md`.

**Scoring Categories** (weighted):

| Category | Weight | What It Checks |
|----------|--------|----------------|
| Structure | 15% | Root + service Makefiles, .PHONY, .DEFAULT_GOAL |
| Help System | 10% | Awk-based help, ## annotations, ##   arg annotations |
| Naming Convention | 15% | `<action>-<service>-<subtype>` pattern |
| Delegation | 15% | Root delegates to service Makefiles, --no-print-directory |
| JSON Output | 20% | FORMAT branching, _PASS, _SCRIPT_FLAGS |
| Test Abstraction | 15% | Runner scripts, aggregation, framework abstraction |
| Database Seeding | 10% | _TEST_DB_SEEDED guard, leaf-only, no file sentinels |

**Rating Scale**:
- 90-100: EXCELLENT - Fully compliant
- 70-89: GOOD - Minor gaps
- 50-69: FAIR - Several issues to address
- 0-49: NEEDS WORK - Significant gaps

---

## 1. Run Deterministic Scan

```bash
~/.claude/scripts/makefile-audit.sh --stage all
```

The script outputs structured JSON to stdout plus writes to `/tmp/makefile-audit-result.json`.

---

## 2. Analyze Results (LLM Phase)

After the script completes, read `/tmp/makefile-audit-result.json` and provide qualitative analysis.

### Based on `next_action`:

**`display_summary`**: Score is high, few/no issues.
- Present the score card
- Note any warnings as optional improvements
- Suggest running `/testing-audit` next

**`generate_report_with_fixes`**: Failures found.
- For each **failed** check:
  1. Explain **why** this matters (referencing the standard in `~/.claude/docs/reference/makefile.md`)
  2. Provide a **specific fix** with the exact Makefile code to add/change
  3. Show which file to edit
- For each **warning**: explain the gap and recommend priority
- Group fixes by category

**`generate_report_with_recommendations`**: Mostly passing but several warnings.
- Present the score card
- List warnings grouped by category
- Recommend which to address first

### Category-Specific Analysis

**Structure**: Verify all components from PROJECT.yaml have corresponding Makefiles.

**Help System**: Check the awk pattern includes `[a-zA-Z0-9_-]` (digits required for targets like `test-e2e`). Verify `##   ARG=value` annotations exist on targets that accept FORMAT/FILES/FILTER.

**Naming**: Verify root Makefile uses `test-<service>` not abbreviated names. Check for `test-<service>-<subtype>` drill-down targets.

**Delegation**: Verify root targets use `$(MAKE) --no-print-directory -C <service>` and forward args via `$(_PASS)`.

**JSON Output**: Verify `ifdef FORMAT` branching, `_PASS` and `_SCRIPT_FLAGS` variables, runner script calls in FORMAT mode.

**Test Abstraction**: Verify runner scripts exist (`test-jest.sh`, `test-playwright.sh`, etc.), aggregation uses `test-aggregate.sh` with tmpdir pattern.

**Database Seeding**: Verify `_TEST_DB_SEEDED` env var guard, leaf-only prerequisite, no file-based sentinels.

---

## 3. Generate Report

Present findings in this format:

```
Makefile Implementation Audit
================================================================

Project: ${PROJECT_NAME}
Date: ${DATE}

Overall Score: ${OVERALL}/100 (${STATUS})

Category Breakdown:
  Structure:          ${SCORE}/100  (weight: 15%)
  Help System:        ${SCORE}/100  (weight: 10%)
  Naming Convention:  ${SCORE}/100  (weight: 15%)
  Delegation:         ${SCORE}/100  (weight: 15%)
  JSON Output:        ${SCORE}/100  (weight: 20%)
  Test Abstraction:   ${SCORE}/100  (weight: 15%)
  Database Seeding:   ${SCORE}/100  (weight: 10%)

Checks: ${PASSED} passed, ${FAILED} failed, ${WARNINGS} warnings

Top Issues:
${PRIORITIZED_FINDINGS}

Recommendations:
${ACTION_PLAN}
```

---

## 4. Offer Follow-Up Actions

**If score >= 90**:
- "Makefiles look excellent. Fully aligned with standards."
- Suggest running `/testing-audit` next

**If score 70-89**:
- List specific fixes needed
- Offer to implement fixes now
- "Run `/makefile-audit` again after fixes to verify"

**If score 50-69**:
- Show prioritized fix plan
- Offer to fix critical issues first
- "Consider `/makefile-init` if Makefiles need significant rework"

**If score < 50**:
- Recommend `/makefile-init` for fresh generation
- Provide step-by-step remediation plan

---

## Important Notes

- **Non-destructive**: Only reads files, makes no changes
- **Repeatable**: Safe to run multiple times
- **PROJECT.yaml required**: Script reads component list from PROJECT.yaml
- **Quick mode**: Use `--quick` on the script to skip seeding checks
- **Reference**: `~/.claude/docs/reference/makefile.md` and `~/.claude/docs/reference/testing.md`

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-audit" --event complete \
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

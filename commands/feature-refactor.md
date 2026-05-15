---
name: feature-refactor
description: Analyze a feature for refactoring opportunities to improve stability, scalability, and simplicity.
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-refactor" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-refactor" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Feature Refactor Analysis

I will review a feature to identify opportunities where a refactor could optimize the code, make it more stable, scalable, or simpler.

**CRITICAL: Safety & Isolation Requirements**
1. **Branching**: All refactoring work MUST be performed in a dedicated feature branch. I will never refactor directly on the main development branch.
2. **Baseline Testing**: Before any code is modified, I will ensure comprehensive E2E tests are in place and passing:
   - **UI**: Playwright tests
   - **Backend**: Newman (Postman) tests
3. **Verification**: These tests will serve as the "gold standard" to ensure no behavioral regressions occur during the refactor.

**Template**: `~/.claude/templates/feature/feature-refactor.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-RFA-[feature-name].md`

---

## 0. Load Project Knowledge (if available)

Check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists. If it does, read it before analysis — it maps service dependencies, entity relationships, and integration flows that are critical for safe refactoring (e.g., knowing ClearanceService depends on DisqualificationService, or that patient status changes trigger Zoho outbound sync). Skip if it doesn't exist.

## 1. Feature Discovery & Setup

- Identify the core "feature-name" for the filename.
- **Branch Check**: Ensure we are on a dedicated feature branch. If not, I will offer to create one.
- **Test Baseline**: Identify or create Playwright (UI) and Newman (Backend) E2E tests.
- **Initial Run**: Run all E2E tests and confirm they pass before starting analysis.

---

## 2. Refactoring Assessment

Evaluate across four pillars:
- **Optimization**: Redundancy, inefficiency.
- **Stability**: Error handling, validation, type safety.
- **Scalability**: Bottlenecks, decoupling, async opportunities.
- **Simplicity**: Complexity reduction, design patterns.

---

## 3. Report Generation

I will generate the refactor analysis document directly to `docs/features/active/`.

**Naming Convention**:
1. Get current timestamp (YYMMDDHHMM).
2. Create filename: `docs/features/active/[YYMMDDHHMM]-RFA-[feature-name].md`.

---

## 4. Next Steps

After creating the file, I will ask if you would like to:
- Turn specific refactoring steps into tasks using `/feature-to-task`.
- Run a performance baseline using `/feature-performance`.
- **Execute**: Begin the refactor on this branch, starting with the baseline tests.

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-refactor" --event complete \
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
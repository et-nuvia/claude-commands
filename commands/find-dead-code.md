---
name: find-dead-code
description: Search for, analyze, and safely remove dead code with mandatory E2E test verification.
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "find-dead-code" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "find-dead-code" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Dead Code Analysis & Removal

I will search for dead code (unused functions, exports, or unreachable logic), verify functional integrity with E2E tests, and safely remove it.

**Template**: `~/.claude/templates/feature/dead-code-removal.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-DEAD-[symbol-name].md`

---

## 1. Discovery Phase

I will scan the codebase for:
- **Unused Exports**: Exported symbols that are not imported anywhere else in the project.
- **Uncalled Methods**: Private or internal functions that have no call sites.
- **Unreachable Logic**: Code blocks following `return`, `throw`, or `break` statements that can never be executed.
- **Dangling Dependencies**: Files that are no longer imported by the entry point or other active files.

---

## 2. Context & Risk Analysis

For each candidate:
1. Determine the original purpose and feature relationship.
2. Identify existing **Playwright (UI)** or **Newman (Backend)** tests that cover the area this code was part of.

---

## 3. Mandatory Testing Workflow

Before deleting any code:
1. **Check Coverage**: If no Playwright or Newman tests cover the relevant functionality, I will **create them first**.
2. **Establish Baseline**: Run the tests to confirm the software works as expected with the code present.
3. **Execution**: Delete the code in a dedicated branch.
4. **Final Verification**: Run the tests again to confirm the software still works perfectly after the removal.

---

## 4. Report Generation

I will generate a dead-code-removal document to `docs/features/active/`.

---

## 5. Next Steps

After the analysis, I will ask:
- "Should I create the missing E2E tests now?"
- "Proceed with the removal on a new branch?"
- "Run a full suite to ensure no side effects?"

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "find-dead-code" --event complete \
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
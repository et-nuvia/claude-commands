---
name: feature-review
description: Review a specific function for implementation quality, improvements, and optimizations.
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-review" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-review" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Feature Review

I will review a specific function and determine if everything is properly implemented, or if there are opportunities to improve or optimize it.

**Template**: `~/.claude/templates/feature/feature-review.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-REV-[feature-name].md`

---

## 0. Load Project Knowledge (if available)

Check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists. If it does, read it before analysis — it provides domain workflows, entity relationships, service maps, and business rules that help you evaluate whether a feature is correctly implemented against the actual business logic (not just code quality). Skip if it doesn't exist.

## 1. Scope Identification

**Identify the function to review**:
- Determine the function or file to analyze.
- Extract a clean "feature-name" for the filename.

---

## 2. Technical Analysis

Perform a deep dive into the function's implementation:
- **Completeness**: Requirements, error handling, edge cases.
- **Improvements**: Readability, maintainability, clean code.
- **Optimizations**: Bottlenecks, memory usage, algorithmic efficiency.

---

## 3. Report Generation

I will generate the review document directly to `docs/features/active/`.

**Naming Convention**:
1. Get current timestamp (YYMMDDHHMM).
2. Create filename: `docs/features/active/[YYMMDDHHMM]-REV-[feature-name].md`.

---

## 4. Next Steps

After creating the file, I will ask if you would like to:
- Turn specific recommendations into tasks using `/feature-to-task`.
- Perform a performance analysis using `/feature-performance`.
- Implement a refactor using `/feature-refactor`.

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-review" --event complete \
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
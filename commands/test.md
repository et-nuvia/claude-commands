---
name: test
description: Run the project test suite with structured output
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "test" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "test" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Smart Test Runner

Run tests intelligently based on current context, and actively help fix failures.

## Context Detection

Determine the situation before running anything:

- **Cold start / no context**: run full test suite with coverage
- **Active development**: check git diff, test only modified files and their dependents
- **Post-command** (after `/scaffold`, `/fix-todos`, `/fix-imports`): test the files that were just changed
- **Failing tests**: focus on failed tests with verbose output and isolation
- **Pre-commit**: full suite + lint + typecheck, no skipped tests

## Phase 1: Project Analysis

Discover the testing setup using Glob, Read, and Grep:
- Test framework and runner (pytest, jest, vitest, go test, etc.)
- Test file patterns and locations
- Coverage requirements (from PROJECT.yaml or config files)
- Available test commands (from Makefile, package.json, pyproject.toml)
- Separation of unit vs integration vs e2e tests

## Phase 2: Test Execution

Run with verbose output and fail-fast when available. Capture both stdout and stderr. Watch for:
- Compilation errors before tests even start
- Port/resource conflicts ("address already in use")
- Memory issues ("heap out of memory")
- Timeout patterns
- Missing environment variables or fixtures

```bash
# Example patterns — use what the project actually has
docker compose run --rm app pytest -x -v --tb=short
docker compose run --rm frontend npm test -- --watchAll=false --verbose
```

## Phase 3: Failure Analysis and Auto-Fix

When tests fail:
1. Parse failure output to identify the exact issue
2. Read the failing test to understand expectations
3. Read the implementation to find the bug
4. Check similar passing tests for the correct pattern
5. Apply a fix when confident; otherwise describe the issue clearly

**Common fixable issues:**
- Async/await timing problems
- Mock/stub misconfiguration
- Import path errors
- Type mismatches
- Null/undefined handling
- Off-by-one errors
- Environment variable gaps

Never modify tests to make them pass incorrectly. Never skip or comment out failing tests — fix them or fix the code.

## Phase 4: Coverage and Quality

After tests pass:
- Generate coverage report if configured
- Flag untested critical code paths
- Note any test anti-patterns observed

## Rules

- Skipped tests = failed tests
- Coverage must meet the threshold in PROJECT.yaml (default 80%)
- All tests must pass before committing or merging
- Never add AI attribution to any commits made during test fixes

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "test" --event complete \
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

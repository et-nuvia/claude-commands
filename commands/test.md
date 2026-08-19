---
name: test
description: Run the project test suite with structured output
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



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

Run tests via `~/.claude/scripts/test-run.sh --json` — it delegates to `make test FORMAT=json` when the Makefile supports it, otherwise it detects the framework, runs it in the right container, and parses the results itself. Capture both stdout and stderr from the output. Watch for:
- Compilation errors before tests even start
- Port/resource conflicts ("address already in use")
- Memory issues ("heap out of memory")
- Timeout patterns
- Missing environment variables or fixtures

```bash
# Cold start / pre-commit: full suite with coverage
~/.claude/scripts/test-run.sh --json --full --coverage-flag

# Active development: test only modified files
~/.claude/scripts/test-run.sh --json --full --file "path/to/changed_test.py"
~/.claude/scripts/test-run.sh --json --full --pattern "test_name_substring"

# Failing tests: re-run only last failures, verbose
~/.claude/scripts/test-run.sh --json --full --failed --verbose
```

### Script flags

- `--json` / `--raw` — output format (default `--json`)
- `--full` / `--detect` / `--run` / `--coverage` / `--parse` — which section to run (default `--full`)
- `--coverage-flag` / `-c` — run the coverage variant of the test command
- `--verbose` / `-v` — verbose test output
- `--failed` / `-f` — only re-run last-failed tests
- `--pattern <pat>` — filter tests by name pattern
- `--file <path>` — run a specific test file

When a Makefile with `FORMAT=json` support exists, these flags are passed through as `make` args automatically — no need to call `make` directly.

**Fallback (only if no Makefile and test-run.sh reports it can't detect a framework):** describe the gap rather than running raw tools directly — `docker compose exec <service> pytest ...` / `npm test` bypasses the project's Makefile-first convention and should be a last resort, not the default path.

## Phase 3: Failure Analysis and Auto-Fix

When tests fail:
1. Parse failure output to identify the exact issue
2. Read the failing test to understand expectations
3. Read the implementation to find the bug
4. Check similar passing tests for the correct pattern
5. Apply a fix when confident; otherwise describe the issue clearly
6. **If the same test still fails after 2 fix attempts, STOP iterating in this context** — dispatch the `debug-investigator` agent with the failing target, the exact failure text, and the attempts already made. It iterates in its own context and returns root cause + fix + ruled-out list; act on that report

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


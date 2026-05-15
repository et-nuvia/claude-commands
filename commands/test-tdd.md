---
name: test-tdd
description: Generate failing tests for TDD workflow (red phase)
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "test-tdd" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "test-tdd" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Generate comprehensive failing tests before any implementation code. This handles the RED phase of TDD.

## Execute

```bash
~/.claude/scripts/test-tdd.sh --full
```

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: generate_tests** — Script has detected framework and loaded context. Use the `framework`, `task_doc`, and `context` fields to generate tests.

Generate tests following these rules:
1. Use AAA pattern (Arrange-Act-Assert) with descriptive test names
2. Cover happy path, edge cases, and error conditions
3. Include fixtures for reusable test data
4. Mock external dependencies, not your own code
5. Write test docstrings explaining what's being tested

After generating, write the test file, then run to verify RED phase (all should fail):
- pytest: `docker compose exec backend pytest <test_file> -v`
- jest/vitest: `docker compose exec frontend npm test -- <test_file>`

Commit with: `test: add failing tests for <feature> (RED phase)`

**next_action: fix_error** — Framework detection failed. Show `message` and `details`. Common fix: add framework to PROJECT.yaml `testing.command` or install dependencies.

## Section Flags

- `--detect` — detect test framework only
- `--context` — load task context only

## Debug

```bash
~/.claude/scripts/test-tdd.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "test-tdd" --event complete \
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

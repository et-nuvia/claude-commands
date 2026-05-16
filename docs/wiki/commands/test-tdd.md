---
command: test-tdd
group: code-quality
backing_script: ~/.claude/scripts/test-tdd.sh
mutates: [files]
runtime: ~30-60s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - testing.command
  - testing.framework
requires_project_knowledge: none
project_knowledge_sections: []
---

# /test-tdd

Handles the RED phase of test-driven development: detects the test framework, loads task context, and generates a comprehensive failing test file. All generated tests are designed to fail until the implementation is written, giving you a verifiable starting point.

> **Config:** PROJECT.yaml optional — reads `testing.command` and `testing.framework` to detect and run the correct test runner.

---

## When to use it

- Starting a new feature and want a test-first workflow
- A task document describes behavior that should be encoded as tests before any code is written
- You want coverage of happy path, edge cases, and error conditions generated in one shot

## Usage

```bash
/test-tdd
```

**Common invocations:**

```bash
/test-tdd                  # detect framework, load context, generate tests
```

## Arguments

None — invoke with no input.

## Dependencies

**External commands / packages** (must be on `PATH` inside container):

| Dependency | Why it's needed | Install |
|---|---|---|
| `pytest` | Run generated Python tests to verify RED phase | `uv pip install pytest` |
| `jest` / `vitest` | Run generated JS/TS tests to verify RED phase | `npm install` |
| `docker compose` | Execute test runner inside container | Docker Desktop / Engine |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `testing.command` / `testing.framework` used for framework detection.
- Task document (active TSK file) — loaded as context for test generation if present.

## Backing script

**Script**: `~/.claude/scripts/test-tdd.sh`

**Inputs:** `--full`, `--detect`, `--context`. Reads PROJECT.yaml for test framework config.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`generate_tests`, `fix_error`}
- `framework` — detected test framework (`pytest`, `jest`, `vitest`, …)
- `task_doc` — path to active task document if found
- `context` — relevant code context loaded for generation

**Invocation surface:**

```bash
~/.claude/scripts/test-tdd.sh --full       # detect + load context
~/.claude/scripts/test-tdd.sh --detect     # detect framework only
~/.claude/scripts/test-tdd.sh --context    # load task context only
~/.claude/scripts/test-tdd.sh --raw --full # debug
```

## How it works

1. **Detect** — script identifies the test framework from PROJECT.yaml or by inspecting config files (`pyproject.toml`, `package.json`, `vitest.config.ts`, etc.).
2. **Load context** — active task document (TSK) and relevant source files are surfaced so the LLM understands what needs to be tested.
3. **Generate** — LLM writes tests following AAA (Arrange-Act-Assert), covering happy path, edge cases, and error conditions. External dependencies are mocked; project code is not.
4. **Verify RED** — generated test file is written, then run inside the Docker container. All tests must fail. If any pass, the test is not testing unwritten behavior and should be revised.
5. **Commit** — committed with message `test: add failing tests for <feature> (RED phase)`.

## Example workflows

### Scenario: TDD start-to-finish

```
/task-start 42
/test-tdd
# implement until tests pass
/git-commit
```

`/test-tdd` generates the test file; implementation proceeds until `make test` goes green.

### Scenario: Framework detected, tests generated

```
/test-tdd
```

```
Framework detected: pytest
Task context: docs/features/active/42-TSK-add-payment-retry.md
Writing: tests/test_payment_retry.py  (12 tests)
Running RED phase verification…
  FAILED tests/test_payment_retry.py::test_retry_on_timeout - NotImplementedError
  FAILED tests/test_payment_retry.py::test_max_retries_respected - NotImplementedError
  … 12 failed, 0 passed ✓ RED phase confirmed
```

## Notes & gotchas

- Tests must be run inside the Docker container — never on the host directly.
- If framework detection fails, add `testing.framework` to PROJECT.yaml or ensure `pyproject.toml` / `package.json` is present and configured.
- **If it fails:** run `~/.claude/scripts/test-tdd.sh --raw --full` to inspect detection output. If framework is missing from `PATH` inside the container, install it there first.
- A passing test during the RED phase means either the feature already exists or the test is too loose — revisit the assertion.

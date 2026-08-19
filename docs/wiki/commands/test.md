---
command: test
group: code-quality
backing_script: ~/.claude/scripts/test-run.sh
mutates: [docker]
runtime: as long as the suite takes
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - testing.coverage_threshold
  - components
requires_project_knowledge: none
project_knowledge_sections: []
---

# /test

Runs the project's test suite and returns structured results — which
tests failed, with what assertion, and where. It prefers the project's
own Makefile over invoking a runner directly, so the suite runs the same
way it runs in CI.

> **Config:** PROJECT.yaml optional — coverage requirements and component
> paths are read from it when present.

---

## When to use it

- Before a commit, and before opening a PR
- After a change, to test only the files that changed
- To re-run just the last failures while fixing them

## Usage

```bash
/test
```

The command reads the situation before running anything: a cold start
gets the full suite with coverage; active development gets only modified
files and their dependents; a failing run gets the failures re-run
verbosely in isolation; pre-commit gets the full suite plus lint and
typecheck with no skips.

## Backing script

**Script**: `~/.claude/scripts/test-run.sh`

It delegates to `make test FORMAT=json` when the Makefile supports it,
and only otherwise detects the framework, runs it in the right container,
and parses the results itself.

**Invocation surface:**

```bash
~/.claude/scripts/test-run.sh --json                                 # default
~/.claude/scripts/test-run.sh --json --full --coverage-flag          # cold start / pre-commit
~/.claude/scripts/test-run.sh --json --full --file "path/to/test.py" # one file
~/.claude/scripts/test-run.sh --json --full --pattern "substring"    # by name
~/.claude/scripts/test-run.sh --json --full --failed --verbose       # re-run failures
```

| Flag | Effect |
|---|---|
| `--json` / `--raw` | Output format (default `--json`) |
| `--full` / `--detect` / `--run` / `--coverage` / `--parse` | Which section runs (default `--full`) |
| `--coverage-flag`, `-c` | Run the coverage variant |
| `--verbose`, `-v` | Verbose test output |
| `--failed`, `-f` | Only re-run last-failed tests |
| `--pattern <pat>` | Filter by test name |
| `--file <path>` | Run one test file |

Where a Makefile with `FORMAT=json` support exists, these are passed
through as `make` arguments automatically — you never need to call `make`
yourself.

## How it works

1. **Analyze** — detect framework, test file patterns, coverage
   requirements, available commands, and the unit/integration/e2e split.
2. **Execute** — run through the Makefile where possible, capturing both
   stdout and stderr. Watches for the failure modes that aren't test
   failures at all: compilation errors before tests start, port conflicts
   ("address already in use"), heap exhaustion, timeouts, missing fixtures
   or environment variables.
3. **Analyze failures** and propose or apply fixes.
4. **Coverage and quality** against the configured threshold.

## Notes & gotchas

- **Read the returned `failures` array — don't pipe the output.** Piping
  through `tail`/`grep`/`jq` drops the runner's exit status and truncates
  the assertion text, so a red suite can look green and has to be re-run
  to find out what broke.
- **The raw-runner fallback is a last resort, not a shortcut.** If no
  Makefile exists and the framework can't be detected, describe the gap
  rather than reaching for `docker compose exec <service> pytest` —
  bypassing the Makefile means you're no longer testing what CI tests.
- Test targets are hierarchical (`test` → `test-<service>` →
  `test-<service>-<type>`). Call the narrowest one that covers what you
  need; aggregators return a `targets` array to drill into.

---

**See also:** [Testing](10-testing) · [`/test-tdd`](test-tdd.md) ·
[`/testing-audit`](testing-audit.md)

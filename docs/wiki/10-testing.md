# Testing

The repo ships with a comprehensive test suite covering every command's
backing script, the shared library layer, and a handful of Python utilities.
Tests are the contract: anything new lands with a test, and the suite must be
green before merge.

> **At a glance.** 55 Bats test files, ~1,080 individual tests, ~870 passing
> (the remainder are intentionally `skip`'d on macOS/WSL-specific paths). Plus
> 8 Python `pytest` files for the Python utilities. End-to-end run takes
> roughly 90 seconds on a modern laptop; `--parallel` cuts that to ~25s.

---

## Quick start

```bash
# All Bats tests
bash scripts/tests/run-tests.sh

# Faster: all tests in parallel
bash scripts/tests/run-tests.sh --parallel

# Just one slice
bash scripts/tests/run-tests.sh task          # everything matching test-task-*.bats
bash scripts/tests/run-tests.sh common git    # multiple filters

# A single file
bats scripts/tests/test-task-continue.bats

# A single test by name
bats scripts/tests/test-task-continue.bats -f "tdd_required yes blocks commit"

# Python tests
bash scripts/tests/run-python-tests.sh
```

### Prerequisites

| Tool | Why | Install |
|---|---|---|
| `bats-core` ≥ 1.10 | Bats test runner | `brew install bats-core` / `npm install -g bats` |
| `jq` | JSON assertions in helpers | `brew install jq` / `apt install jq` |
| `yq` (Go variant, v4) | YAML assertions in helpers | `brew install yq` / Go install |
| `uv` (recommended) or `python3` + `pytest` | Python tests | `brew install uv` |

`run-tests.sh` checks for `bats`, `jq`, and `yq` and fails early with an
install hint if any are missing. `run-python-tests.sh` prefers `uv` and falls
back to system `python3` with an auto-install of `pytest`.

---

## What the suite covers

### Task lifecycle (`test-task-*.bats`)

| File | What it covers |
|---|---|
| `test-task-capture.bats` | Capture from issue / URL / direct input; backend dispatch |
| `test-task-start.bats` | Branch / worktree creation, backend validation, env setup |
| `test-task-continue.bats` | Plan-progress integration, TDD enforcement, commit staging |
| `test-task-lifecycle.bats` | Cross-stage flows: hold → resume, close → reopen |
| `test-task-recover.bats` | Recovering context after branch rename / lost `.current-task` |
| `test-task-fetch.bats` | Listing assigned tasks from Asana / GitLab |
| `test-task-context.bats` | `check-current-task.sh` + `resolve_task_context` helpers |
| `test-task-design.bats` | DSN doc creation and decision tracking |
| `test-task-reporting.bats` | task-audit, task-summary, task-code-review, deploy-risk |
| `test-task-commands.bats` | Command-level contracts (size limits, no `jq` in `.md`, etc.) |
| `task-close.bats` | Closeout: pre-merge verify, doc moves, lockfile checkpointing |
| `check-current-task.bats` | `.current-task` parsing + branch-mismatch surfacing |

### Deployment (`test-deploy-*.bats`, `get-config-deploy.bats`)

| File | What it covers |
|---|---|
| `test-deploy-scripts.bats` | Shared deploy helpers, risk-threshold mapping |
| `test-deploy-stage-prod.bats` | `--validate`, idempotency, conflict handling |
| `test-pre-merge-verify.bats` | Pre-merge rebase / lint / test / build flow + PROJECT.yaml fallback |
| `get-config-deploy.bats` | PROJECT.yaml deployment-target resolution |

### Git platform (`test-git-*.bats`, `test-pipeline-*.bats`)

| File | What it covers |
|---|---|
| `test-git-api-contract.bats` | `lib/git-api.sh` adapter contract (GitHub + GitLab) |
| `test-git-detect.bats` | Platform detection from git remote |
| `test-git-merge-flags.bats` | `git-merge.sh` flag parsing, squash vs regular |
| `test-git-commit-sections.bats` | Conventional-commit section flow |
| `test-git-operations.bats` | Branch helpers, default-branch detection |
| `test-pipeline-scripts.bats` | `pipeline-status/jobs/logs/watch` adapter routing |
| `test-pipeline-management.bats` | Pipeline lookup + polling helpers |
| `test-pipeline-audit.bats` | CI config audit checks |

### Library layer (`test-lib-*.bats`, `test-common.bats`, `test-doc-utils.bats`)

| File | What it covers |
|---|---|
| `test-common.bats` | `common.sh`: `normalize_task_id`, `load_current_task`, helpers |
| `test-doc-utils.bats` | `doc-utils.sh`: V4 doc naming, find-by-id, status detection |
| `test-lib-output-framework.bats` | `exit_with_json`, JSON envelope contract |
| `test-lib-platform.bats` | Platform helpers (macOS vs Linux) |
| `test-lib-new.bats` | Newer lib additions (templates, project-knowledge) |
| `test-yaml.bats` | `yaml_get`/`yaml_get_default` against `yq` Go + Python variants |
| `test-secrets-api-contract.bats` | Secrets adapter (Infisical + AWS Secrets Manager) |
| `test-task-api-contract.bats` | `lib/task-api.sh` adapter contract (Asana + GitLab + GitHub) |
| `test-task-api-normalize.bats` | ID normalization across backends |

### Cross-cutting (`test-script-contracts.bats`, `test-section-dispatch.bats`)

| File | What it covers |
|---|---|
| `test-script-contracts.bats` | Every core script: `set -euo pipefail`, proper shebang, `bash -n` |
| `test-section-dispatch.bats` | `--full` vs `--<section>` flag dispatching |
| `test-arg-parsing.bats` | Standard `--json` / `--raw` / `--task-id` flag parsing |
| `test-exit-with-json.bats` | Error-path JSON validity for every script |
| `test-log-output-modes.bats` | `--json` suppresses logs; `--raw` shows them |

### Domain-specific

| File | What it covers |
|---|---|
| `test-db-scripts.bats` | `db-performance/backup/restore/upgrade/user-audit` |
| `test-infra-scripts.bats` | Terraform `infra-plan/apply/destroy/drift/verify` |
| `test-security-scripts.bats` | `security-audit`, secret detection |
| `test-secret-rotation.bats` | Rotation lifecycle |
| `test-ops-scripts.bats` | Monitoring, scaling, capacity, cost, load-test |
| `test-rca-scripts.bats` | `rca-triage/timeline/analyze/pir` |
| `test-reviews.bats` | `review-pr`, `review-implement` |
| `test-plan-progress.bats` | PLN parsing, subtask advancement |
| `test-plan-review.bats` | Plan-quality gates (size, AC tags, dependency direction) |
| `test-generators.bats` | `dockerfile-build`, `makefile-init`, `pipeline-create` |
| `test-project-config.bats` | `PROJECT.yaml` detection and validation |
| `test-docker-exec.bats` | `docker-exec.sh` service-name resolution |
| `test-detect-scripts.bats` | `detect-tech-stack`, `detect-database`, `detect-environment` |
| `test-misc-scripts.bats` | `format`, `cleanproject`, `fix-imports`, `find-todos`, etc. |
| `test-doc-management.bats` | Doc move/index/range-folder helpers |
| `test-analyze-config-usage.bats` | `analyze-config-usage.sh` audit reporting |
| `test-code-quality.bats` | Repo-wide style assertions |
| `arch-explore.bats`, `arch-grill.bats`, `arch-interfaces.bats` | Architecture-deepening workflow |
| `task-merge.bats` | `task-merge.sh` (squash merge wrapper) |

### Python tests (`test-*.py`, `test_*.py`)

| File | What it covers |
|---|---|
| `test-project-config-detect.py` | Project-config auto-detection rules |
| `test_analyze_har.py` | `analyze-har.py` HAR parsing for network audit |
| `test_coverage_report.py` | `coverage-report.py` coverage aggregation |
| `test_docker_audit.py` | `docker-audit.py` security/hardening checks |
| `test_docker_audit_consolidate.py` | Multi-Dockerfile result merging |
| `test_generate_release_notes.py` | Release-notes generator from conventional commits |
| `test_validate_project.py` | `PROJECT.yaml` shape validation |
| `test_validate_project_yaml.py` | Field-level schema validation |

---

## Conventions

- **One file per script.** `test-<name>.bats` tests `scripts/<name>.sh`.
  Cross-script flows live in lifecycle / contract files (e.g.,
  `test-task-lifecycle.bats`).
- **Setup via `common_setup`.** Almost every Bats file does `load test_helper`
  and calls `common_setup` to set up a fresh `TEST_DIR`, `TEST_BIN` on PATH,
  and a clean environment. See `scripts/tests/test_helper.bash`.
- **Mocks live in `TEST_BIN`.** Helpers like `create_mock "curl" '<body>'`
  drop a shell script into `TEST_BIN/` so the script under test can't reach
  real services. Adapter-pattern scripts (`gitlab_api`, `task_get`) require
  more careful mocks — see `test-pipeline-scripts.bats` for the
  `-o tmpfile -w '%{http_code}'` invocation pattern.
- **Fixtures in `fixtures/`.** Reusable `PROJECT.yaml` shapes
  (`complete-gitlab.yaml`, `complete-github.yaml`, etc.) live there. Copy via
  `setup_mock_project "complete-gitlab"`.
- **Assertions via `test_helper.bash` helpers.** `assert_valid_json "$output"`,
  `assert_json_field "$output" ".status" "error"`, `assert_json_field_present`,
  etc. Use these instead of raw `jq` so failures show the offending JSON.

---

## Adding a new test

1. **Pick the right file.** A new task-management script → `test-task-*.bats`
   or a new file `test-<script>.bats`. A new shared helper → `test-lib-*.bats`
   or `test-common.bats`.
2. **Start from setup.** Copy the `setup()` / `teardown()` block from a
   neighboring file; nearly all tests share `common_setup` + a script-specific
   fixture.
3. **Test the JSON envelope first.** Every script returns structured JSON.
   The cheapest first test is "missing required arg returns `status:error` and
   `next_action:fix_error`."
4. **Mock at the boundary.** Mock `curl`, `gh`, `glab`, `asana_*` MCP tools.
   Don't mock the script's own helpers — that just tests your mock.
5. **Add a row to this page** if the file is new. The table above is the
   index; if it doesn't list your file, future contributors won't know what
   it covers.
6. **Run the suite.** `bash scripts/tests/run-tests.sh --parallel` should
   stay green. CI runs the same script.

---

## Debugging a failing test

```bash
# See full output, including stderr
bats scripts/tests/test-foo.bats -f "specific test name"

# Even more detail: run the script under test directly in a scratch dir
cd $(mktemp -d) && git init -q && \
  ~/.claude/scripts/<script>.sh --raw --full --task-id ABC123
```

- The `run-tests.sh` summary shows `Files: N passed, M failed (T total)` and
  `Tests: N passed, M failed, S skipped (T total)`. If only one or two tests
  fail, run them individually for the full trace.
- Bats merges stdout + stderr into `$output`. If you redirect via `exec` in
  the script-under-test, the test mock must use real-stdout writes (fd 3,
  per the `output-framework.sh` convention) or the JSON will be polluted.
- `set -u` errors masquerading as test failures usually mean a global was
  referenced before declaration. Pre-declare with `: "${VAR:=}"` at module
  scope (see `common.sh` for the `CT_*` family).

---

## CI

The same `run-tests.sh` invocation runs in CI on every push to `main` and
every PR. A failing test blocks merge. The Python suite runs alongside via
`run-python-tests.sh`. Both must be green.

If you need to land a known-flaky test, use Bats `skip` with a comment
explaining the trigger condition — never delete a test or downgrade an
assertion to make red turn green.

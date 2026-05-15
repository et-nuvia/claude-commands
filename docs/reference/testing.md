# Testing Best Practices

Guidelines for writing effective, maintainable tests and executing them via Makefile.

---

## Test Execution via Makefile

**All test execution goes through Makefile targets.** Never run test tools directly (`pytest`, `jest`, `bats`, `playwright`, `newman`).

### Why Makefile Targets

The Makefile is an **abstraction layer**. Neither the developer nor the LLM needs to know which framework runs, what flags it needs, whether tests run inside Docker, or how to parse its output. They call the target and get results.

- **Framework-agnostic**: Same interface whether it's Jest, pytest, Playwright, Newman, or BATS
- **LLM-optimized**: Structured JSON output — no parsing raw terminal output with tail/head/grep
- **Hierarchical drill-down**: Start broad (`make test`), narrow to the failing area (`make test-backend-unit`)
- **Transparent containerization**: If tests need a database or specific runtime, the Makefile handles it — the caller doesn't know or care
- **AI auto-detected**: Claude Code, Cursor, Codex, and Gemini get JSON output automatically — no `FORMAT=json` needed

| What the caller does | What actually happens (varies by project) |
|---------------------|------------------------------------------|
| `make test-backend-unit` | Framework runs (Jest, pytest, etc.), output parsed by runner script into standard JSON |
| `make test-backend-e2e` | E2E framework runs (Playwright, etc.), output parsed into standard JSON |
| `make test-backend-api` | Newman runs collections against live endpoints, output parsed into standard JSON |
| `make test-backend` | Sub-targets run, results aggregated by `run-aggregate.sh` |
| `make test` | All service aggregators run, results aggregated again at root level |

See: [Makefile Best Practices](makefile.md) for the full delegation pattern, AI auto-detection, `_PASS`/`_SCRIPT_FLAGS` variables, and `ifdef FORMAT` branching.

### Inside vs Outside Testing

Tests run at two boundaries:

- **Inside tests** (unit, integration): Call functions directly, hit the database, test internal behavior. When Docker is present, these run *inside* the container via `docker compose run --rm <service>`. Without Docker, they run natively on the host.
- **Outside tests** (API contract): Hit the service over HTTP as a consumer would. Newman, Playwright for APIs, or any HTTP test tool. These always run *from outside* the container, testing the public contract.

Both can live under the same service aggregator (e.g., `test-backend` → `test-backend-unit` + `test-backend-api`). The Makefile abstracts this — the caller doesn't know whether tests run inside or outside a container.

### Target Hierarchy

Targets form a cascade following the `<action>-<service>-<subtype>` naming convention. Each level aggregates its children. Service names come from `components[].path` in PROJECT.yaml.

```
make test                              # Aggregates all test-<service> targets
├── make test-bats                     # BATS shell script tests (if present)
├── make test-backend                  # Aggregates backend test types
│   ├── make test-backend-unit         # Jest/pytest unit tests
│   ├── make test-backend-e2e          # Jest/pytest E2E tests
│   └── make test-backend-api          # Newman API contract tests
├── make test-frontend                 # Aggregates frontend test types
│   ├── make test-frontend-unit        # Jest/vitest unit tests
│   └── make test-frontend-e2e         # Playwright browser E2E tests
```

**Root Makefile targets** (`test-backend`, `test-backend-unit`) delegate to service Makefiles via `$(MAKE) -C <service>`. The service Makefile owns the implementation — it knows the framework, the runner script, the flags.

**Naming convention**: `test-<service>-<type>`. The pattern is flexible — a single-service project might just have `test-unit`, `test-api`, `test-e2e`. A multi-service project uses `test-<service>-<type>`. What matters is the hierarchy.

**Why this matters for LLM efficiency**: When `make test` shows failures only in `test-backend`, the LLM calls `make test-backend` directly. If only `test-backend-unit` fails, it calls that. Each narrower call eliminates everything else, saving tokens and time.

### Arguments

| Arg | Purpose | Example |
|-----|---------|---------|
| `FORMAT=json` | Structured JSON output (auto-detected for AI) | `make test FORMAT=json` |
| `FORMAT=raw` | Raw framework output for debugging | `make test-bats FORMAT=raw` |
| `FILES="a.spec.ts b.spec.ts"` | Run specific test files only | `make test-backend-unit FILES="auth.spec.ts"` |
| `FILTER="pattern"` | Run tests matching a name pattern | `make test-backend-unit FILTER="clearance"` |
| `SUITES="auth,users"` | Run specific test suites | `make test-backend SUITES="auth,users"` |
| `DETAILS=1` | Include per-test durations and timing stats | `make test FORMAT=json DETAILS=1` |
| `COLLECTION="file.json"` | Run specific Newman collection | `make test-backend-api COLLECTION="auth.json"` |

### FORMAT Modes

| FORMAT value | Output | Use case |
|---|---|---|
| *(unset)* | Human-friendly colored output | Developer in terminal |
| `json` | Standard JSON contract (see below) | LLM, CI, scripts — auto-detected for AI callers |
| `raw` | Raw framework output, no transformation | Debugging when JSON obscures the real error |

When FORMAT is unset and an AI tool is detected (CLAUDECODE, CURSOR_SESSION_ID, CODEX_CLI, GEMINI_API_KEY, AI_AGENT), FORMAT defaults to `json` automatically. See: [Makefile Best Practices — AI Auto-Detection](makefile.md#ai-auto-detection).

---

## JSON Output Contract

When `FORMAT=json` is set, all test targets produce **pure JSON on stdout** — no directory paths, no Make banners, no ANSI colors, no progress bars.

### Contract Versioning

The JSON contract includes a `version` field to support migration between schema versions:

| Version | Status | Introduced | Key differences |
|---------|--------|------------|-----------------|
| 1 | Legacy | Pre-2026 | No `version` field, `failed_tests` array, `warning` (singular), no `status`, no `duration_ms`, no `warning_details` |
| 2 | **Current** | 2026-03 | `version: 2`, `status` field, `failures` array with `suite`/`test`/`message`/`summary`, `warnings` (plural), `duration_ms`, `warning_details` |

**Detection rule:** If `version` field exists, use that version. If absent, assume V1.

**Runner scripts** must output V2. **Consuming scripts** (`run-aggregate.sh`, LLM tooling, CI parsers) must check `version` and normalize V1 → V2 internally when encountering legacy output. This allows gradual migration — old runner scripts keep working while projects upgrade.

#### V1 → V2 Normalization

When a consuming script encounters V1 JSON (no `version` field), it normalizes:

```
V1 field              →  V2 field
─────────────────────────────────────────
(absent)              →  "version": 2
(absent)              →  "status": "fail" if failed > 0 or skipped > 0, else "pass"
"warning": N          →  "warnings": N
"failed_tests": [...]  →  "failures": [...]
  .test               →    .test (keep)
  .summary            →    .message (rename)
  (absent)            →    .suite: "" (empty string)
  (absent)            →    .summary: null (omit)
(absent)              →  "duration_ms": 0
(absent)              →  "warning_details": []
```

### Status Logic

The `status` field is the authoritative pass/fail signal:

- `"pass"` — `failed == 0 AND skipped == 0`
- `"fail"` — `failed > 0 OR skipped > 0`

Warnings do **not** affect `status`. A run with 0 failed, 0 skipped, and 3 warnings is `"pass"`.

### Leaf Targets

Leaf targets run tests directly and return:

```json
{
  "version": 2,
  "target": "test-backend-unit",
  "status": "pass",
  "suites": 12,
  "tests": 87,
  "passed": 85,
  "failed": 2,
  "skipped": 0,
  "warnings": 3,
  "duration_ms": 4523,
  "failures": [
    {
      "suite": "user.service",
      "test": "should reject expired tokens",
      "message": "Expected status REJECTED but received PENDING",
      "summary": "Token expiration boundary not evaluated correctly"
    }
  ],
  "warning_details": [
    "BW01: Deprecated API call in auth.service",
    "Slow test: user.service > bulk import (4.2s)"
  ]
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | number | yes | Contract version (`2` for current standard) |
| `target` | string | yes | Make target name (e.g., `test-backend-unit`) |
| `status` | string | yes | `"pass"` or `"fail"` — authoritative signal |
| `suites` | number | yes | Number of test suites/files executed |
| `tests` | number | yes | Total test count |
| `passed` | number | yes | Tests that passed |
| `failed` | number | yes | Tests that failed |
| `skipped` | number | yes | Tests that were skipped |
| `warnings` | number | yes | Warning count |
| `duration_ms` | number | yes | Total execution time in milliseconds |
| `failures` | array | yes | Failed test details (empty array if none) |
| `failures[].suite` | string | yes | Test file or group name |
| `failures[].test` | string | yes | Specific test name |
| `failures[].message` | string | yes | Raw assertion or error message |
| `failures[].summary` | string | no | Higher-level context when runner script can infer it |
| `warning_details` | array | yes | Warning messages (empty array if none) |

### Leaf Targets with DETAILS=1

When `DETAILS=1` is passed, leaf targets add timing statistics and per-suite breakdown:

```json
{
  "version": 2,
  "target": "test-backend-unit",
  "status": "fail",
  "suites": 12,
  "tests": 87,
  "passed": 85,
  "failed": 2,
  "skipped": 0,
  "warnings": 0,
  "duration_ms": 4523,
  "failures": [
    {
      "suite": "user.service",
      "test": "should reject expired tokens",
      "message": "Expected status REJECTED but received PENDING"
    }
  ],
  "warning_details": [],
  "timing": {
    "min_ms": 3,
    "max_ms": 892,
    "mean_ms": 52.0,
    "median_ms": 31
  },
  "suite_details": [
    {
      "suite": "user.service",
      "file": "user.service.spec.ts",
      "duration_ms": 892,
      "tests": [
        { "test": "should create user", "status": "passed", "duration_ms": 45 },
        { "test": "should reject expired tokens", "status": "failed", "duration_ms": 12 },
        { "test": "should list users", "status": "passed", "duration_ms": 31 },
        { "test": "should skip inactive", "status": "skipped", "duration_ms": 0 }
      ]
    }
  ]
}
```

**DETAILS-only fields:**

| Field | Type | Description |
|-------|------|-------------|
| `timing` | object | Aggregate timing statistics across all tests |
| `timing.min_ms` | number | Fastest individual test |
| `timing.max_ms` | number | Slowest individual test |
| `timing.mean_ms` | number | Average test duration |
| `timing.median_ms` | number | Median test duration |
| `suite_details` | array | Per-suite breakdown with individual test results |
| `suite_details[].suite` | string | Suite/group name |
| `suite_details[].file` | string | Test file path |
| `suite_details[].duration_ms` | number | Total suite duration |
| `suite_details[].tests` | array | Individual test results |
| `suite_details[].tests[].test` | string | Test name |
| `suite_details[].tests[].status` | string | `"passed"`, `"failed"`, `"skipped"`, or `"warning"` |
| `suite_details[].tests[].duration_ms` | number | Individual test duration |

### Aggregator Targets

Aggregator targets combine sub-target results and wrap them in a `targets` array. Each child includes the full contract:

```json
{
  "version": 2,
  "target": "test-backend",
  "status": "fail",
  "suites": 18,
  "tests": 142,
  "passed": 140,
  "failed": 2,
  "skipped": 0,
  "warnings": 1,
  "duration_ms": 8750,
  "failures": [
    {
      "suite": "user.service",
      "test": "should reject expired tokens",
      "message": "Expected status REJECTED but received PENDING"
    }
  ],
  "warning_details": [
    "Slow test: user.service > bulk import (4.2s)"
  ],
  "targets": [
    {
      "target": "test-backend-unit",
      "status": "fail",
      "suites": 12,
      "tests": 87,
      "passed": 85,
      "failed": 2,
      "skipped": 0,
      "warnings": 1,
      "duration_ms": 4523,
      "failures": [
        {
          "suite": "user.service",
          "test": "should reject expired tokens",
          "message": "Expected status REJECTED but received PENDING"
        }
      ],
      "warning_details": [
        "Slow test: user.service > bulk import (4.2s)"
      ]
    },
    {
      "target": "test-backend-e2e",
      "status": "pass",
      "suites": 6,
      "tests": 55,
      "passed": 55,
      "failed": 0,
      "skipped": 0,
      "warnings": 0,
      "duration_ms": 4227,
      "failures": [],
      "warning_details": []
    }
  ]
}
```

The `run-aggregate.sh` script:
- Calls each sub-target via `make <target> FORMAT=json`
- Collects and sums `suites`, `tests`, `passed`, `failed`, `skipped`, `warnings` across all children
- Merges all `failures` and `warning_details` arrays
- Sets `status` to `"fail"` if any child has `status: "fail"`
- Includes each child's full JSON as an entry in the `targets` array
- With `DETAILS=1`, passes it through to children and computes aggregate `timing` stats

The LLM reads `status` to know pass/fail, `failures` to know what broke, and `targets` to decide which specific target to re-run.

### V1 Legacy Contract (Reference)

V1 JSON has no `version` field. Consuming scripts detect this and normalize to V2 internally.

```json
{
  "target": "test-backend-unit",
  "suites": 12,
  "tests": 87,
  "passed": 85,
  "failed": 2,
  "warning": 0,
  "skipped": 0,
  "failed_tests": [
    {
      "test": "UserService > should reject expired tokens",
      "summary": "Expected status REJECTED but received PENDING"
    }
  ]
}
```

**V1 aggregator targets** use the same structure with a `targets` array:

```json
{
  "target": "test-backend",
  "suites": 18,
  "tests": 142,
  "passed": 140,
  "failed": 2,
  "warning": 0,
  "skipped": 0,
  "failed_tests": [
    { "test": "UserService > should reject expired", "summary": "..." }
  ],
  "targets": [
    { "target": "test-backend-unit", "suites": 12, "tests": 87, "passed": 85, "failed": 2 },
    { "target": "test-backend-e2e", "suites": 6, "tests": 55, "passed": 55, "failed": 0 }
  ]
}
```

**Key V1 → V2 differences:**

| Aspect | V1 | V2 |
|--------|----|----|
| Version field | absent | `"version": 2` |
| Pass/fail | Infer from `failed > 0` | Explicit `"status": "pass\|fail"` |
| Failed details | `"failed_tests": [{test, summary}]` | `"failures": [{suite, test, message, summary?}]` |
| Warnings | `"warning": 0` (count, singular) | `"warnings": 0` (count, plural) + `"warning_details": [...]` |
| Duration | absent | `"duration_ms": 4523` (always present) |
| Timing stats | absent | `"timing": {...}` (with DETAILS=1) |
| Suite breakdown | absent | `"suite_details": [...]` (with DETAILS=1) |

**Migration path:** Update runner scripts to output V2. Consuming scripts handle both versions via the normalization table in [Contract Versioning](#contract-versioning) above.

---

## Runner Scripts

Each test framework has a dedicated runner script in `scripts/` that translates between the Makefile interface and the framework's native CLI.

### Script Inventory

Only include runner scripts for frameworks your project actually uses:

```
scripts/
├── run-jest.sh              # Jest → standard JSON (TypeScript/JavaScript)
├── run-pytest.sh            # pytest → standard JSON (Python)
├── run-playwright.sh        # Playwright → standard JSON (E2E browser)
├── run-newman.sh            # Newman → standard JSON (API contract)
├── run-bats.sh              # BATS → standard JSON (bash/shell)
├── run-aggregate.sh         # Combines multiple sub-target JSON results
```

### Runner Script Contract

Every runner script must:

1. Accept standard flags: `--target`, `--files`, `--filter`, `--suites`, `--details`, `--raw`
2. Translate flags into framework-specific CLI args
3. Run the framework silently, capturing raw output to a temp file
4. Parse framework-native output (Jest JSON, pytest JUnit, etc.) into the standard JSON contract
5. Return the standard JSON on stdout
6. **Exit 0 in JSON mode** — the `status` field carries pass/fail, not the exit code. This prevents Make from aborting mid-aggregation when a sub-target has failures.
7. **Exit with the framework's native exit code in human mode** — so developers see expected red/green terminal behavior.

When `--raw` is passed, the script runs the framework and passes through its raw output without JSON transformation. Exit code follows the framework in raw mode.

### SUITES Translation

Runner scripts translate `--suites` into framework-specific targeting:

| Framework | `--suites "auth,users"` becomes |
|-----------|--------------------------------|
| pytest | `-k "auth or users"` or path-based `tests/auth tests/users` |
| Jest | `--testPathPattern="(auth\|users)"` |
| Playwright | `--project="auth" --project="users"` |
| Newman | Collection folder filtering |
| BATS | File matching `*auth* *users*` |

### Script Directory Reference

Define `SCRIPTS_DIR` at the top of each Makefile for consistent script references:

Root Makefile:
```makefile
SCRIPTS_DIR := scripts
```

Service Makefile:
```makefile
SCRIPTS_DIR := ../scripts
```

Usage is always the same:
```makefile
	@$(SCRIPTS_DIR)/run-jest.sh --target test-backend-unit $(_SCRIPT_FLAGS)
```

### Test Frameworks

| Framework | Purpose | Runner Script |
|-----------|---------|---------------|
| Jest | JS/TS unit/integration tests | `run-jest.sh` |
| vitest | JS/TS unit tests (Vite projects) | `run-vitest.sh` |
| pytest | Python unit/integration/E2E | `run-pytest.sh` |
| Playwright | Browser E2E tests | `run-playwright.sh` |
| Newman | API contract tests (HTTP) | `run-newman.sh` |
| BATS | Bash/shell script tests | `run-bats.sh` |

**Newman** is the API testing equivalent of Playwright for browser tests. It runs Postman/Newman collections against live endpoints, testing request/response contracts, auth flows, and error handling from outside the service.

### Adding a New Test Framework

1. Create `$(SCRIPTS_DIR)/run-<framework>.sh` following the runner script contract above
2. Add a `test-<name>` leaf target to the service Makefile with `ifdef FORMAT` branching
3. Add the target name to `TEST_TARGETS` in the parent aggregator
4. Add a corresponding `test-<service>-<name>` delegation target in the root Makefile

---

## Implementation Pattern

### Leaf Targets

Leaf targets call a runner script directly. The service Makefile owns the framework choice:

```makefile
SCRIPTS_DIR := ../scripts

_SCRIPT_FLAGS = $(if $(FILES),--files "$(FILES)") \
                $(if $(FILTER),--filter "$(FILTER)") \
                $(if $(SUITES),--suites "$(SUITES)") \
                $(if $(DETAILS),--details)

test-unit: ## Run unit tests
##   FORMAT=json          Output results as JSON
##   FILES="file.spec.ts" Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
ifdef FORMAT
ifeq ($(FORMAT),raw)
	@$(SCRIPTS_DIR)/run-jest.sh --target test-backend-unit --raw $(_SCRIPT_FLAGS)
else
	@$(SCRIPTS_DIR)/run-jest.sh --target test-backend-unit $(_SCRIPT_FLAGS)
endif
else
	@echo "Running unit tests..."
	npx jest $(FILES) $(if $(FILTER),-t "$(FILTER)")
endif
```

### Aggregator Targets

Aggregator targets use a `TEST_TARGETS` variable and delegate to `run-aggregate.sh`:

```makefile
# Service Makefile — aggregates unit + e2e + api for this service
TEST_TARGETS := test-unit test-e2e test-api

_PASS = $(if $(FORMAT),FORMAT=$(FORMAT)) $(if $(FILES),FILES=$(FILES)) \
        $(if $(FILTER),FILTER=$(FILTER)) $(if $(DETAILS),DETAILS=$(DETAILS)) \
        $(if $(SUITES),SUITES=$(SUITES))

test: ## Run all tests (unit + e2e + api)
##   FORMAT=json          Output results as JSON
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include timing breakdown
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test-backend \
		--targets "$(TEST_TARGETS)" $(_PASS)
else
	$(MAKE) test-unit
	$(MAKE) test-e2e
	$(MAKE) test-api
endif
```

```makefile
# Root Makefile — aggregates across all services
TEST_TARGETS := test-bats test-backend test-frontend

test: ## Run all tests (all services)
##   FORMAT=json          Output results as JSON
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include timing breakdown
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test \
		--targets "$(TEST_TARGETS)" $(_PASS)
else
	$(MAKE) test-bats
	$(MAKE) test-backend
	$(MAKE) test-frontend
endif
```

Adding a new sub-target is one line:
```makefile
TEST_TARGETS := test-unit test-e2e test-api test-smoke  # Added test-smoke
```

### API Contract Testing

API contract tests run from outside the service via HTTP, testing the public interface as a consumer would. Newman (Postman collections) is the most common tool, but the pattern applies to any HTTP testing framework.

```makefile
# Leaf: Newman API contract tests (HTTP from outside the service)
test-api: ## Run API contract tests
##   FORMAT=json            Output results as JSON
##   COLLECTION="auth.json" Run specific collection
ifdef FORMAT
ifeq ($(FORMAT),raw)
	@$(SCRIPTS_DIR)/run-newman.sh --target test-backend-api --raw \
		$(if $(COLLECTION),--collection "$(COLLECTION)")
else
	@$(SCRIPTS_DIR)/run-newman.sh --target test-backend-api \
		$(if $(COLLECTION),--collection "$(COLLECTION)")
endif
else
	@echo "Running API contract tests..."
	npx newman run tests/api/*.json $(if $(COLLECTION),--collection "$(COLLECTION)")
endif
```

For projects with multiple distinct API collections (auth, users, billing), split into per-collection leaf targets:

```makefile
API_TEST_TARGETS := test-api-auth test-api-users test-api-billing

test-api: ## Run all API contract tests
##   FORMAT=json            Output results as JSON
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test-backend-api \
		--targets "$(API_TEST_TARGETS)" $(_PASS)
else
	$(MAKE) test-api-auth
	$(MAKE) test-api-users
	$(MAKE) test-api-billing
endif

test-api-auth: ## Run auth API tests
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-newman.sh --target test-backend-api-auth \
		--collection tests/api/auth.json
else
	npx newman run tests/api/auth.json
endif

test-api-users: ## Run users API tests
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-newman.sh --target test-backend-api-users \
		--collection tests/api/users.json
else
	npx newman run tests/api/users.json
endif
```

---

## Database Seeding Strategy

### Seed Once, Run Many

When tests need a seeded database, the seed should run **once** per test invocation — regardless of whether the caller runs `make test`, `make test-backend`, or `make test-backend-unit`. Every subsequent sub-target in that invocation should detect that seeding already happened and skip it.

**Critical requirement**: The seed state must be an **in-memory runtime variable** — never a file on disk. If the user cancels tests mid-run (Ctrl+C), the next invocation must re-seed. A file-based sentinel would survive the killed process and trick the next run into skipping the seed, leaving the database in an unknown partial state.

**Key principle**: Seeding only happens in **leaf targets** — the targets that actually execute test frameworks. Parent/aggregator targets never seed; they just call children and combine results. This means any entry point (root, service, or leaf) eventually reaches a leaf, and the leaf handles seeding.

**Implementation**: Use Make's exported environment variable. The first leaf target to run seeds the DB and exports `_TEST_DB_SEEDED=1`. Subsequent leaf targets (called by the same parent aggregator) inherit the variable and skip seeding. When the process tree dies (Ctrl+C, kill, crash), the variable dies with it — the next `make test` starts fresh.

```makefile
# Service Makefile (e.g., backend/Makefile)

SCRIPTS_DIR := ../scripts

# Seed guard — only leaf targets use this as a prerequisite
_seed-test-db:
ifndef _TEST_DB_SEEDED
	@echo "Seeding test database..."
	@npm run seed:test
	$(eval export _TEST_DB_SEEDED=1)
else
	@echo "Test database already seeded, skipping."
endif

# Aggregator — NEVER seeds, just calls leaf targets
TEST_TARGETS := test-unit test-e2e

test: ## Run all backend tests (unit + e2e)
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test-backend \
		--targets "$(TEST_TARGETS)" $(_PASS)
else
	$(MAKE) test-unit
	$(MAKE) test-e2e
endif

# Leaf targets — these are the ONLY targets that seed
test-unit: _seed-test-db  ## Run backend unit tests
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-jest.sh --target test-backend-unit $(_SCRIPT_FLAGS)
else
	npx jest $(FILES) $(if $(FILTER),-t "$(FILTER)")
endif

test-e2e: _seed-test-db  ## Run backend E2E tests
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-jest.sh --target test-backend-e2e $(_SCRIPT_FLAGS) \
		-- --config ./test/jest-e2e.json
else
	npx jest --config ./test/jest-e2e.json $(FILES) $(if $(FILTER),-t "$(FILTER)")
endif
```

**How it flows at each entry point:**

```
make test                         # Aggregator — does NOT seed
├── make test-unit                # Leaf — _TEST_DB_SEEDED unset → seeds → exports → runs tests
└── make test-e2e                 # Leaf — _TEST_DB_SEEDED=1 inherited → skips seed → runs tests

make test-backend-unit            # Root delegates to backend test-unit
└── make -C backend test-unit     # Leaf — _TEST_DB_SEEDED unset → seeds → runs tests

make test-backend-e2e             # Root delegates to backend test-e2e
└── make -C backend test-e2e      # Leaf — _TEST_DB_SEEDED unset → seeds → runs tests

# User hits Ctrl+C during test-unit...
make test                         # New process → _TEST_DB_SEEDED unset → first leaf seeds again ✓
```

**Passing seed state through sub-makes** (root calling service Makefiles):

```makefile
# Root Makefile
_PASS = $(if $(FORMAT),FORMAT=$(FORMAT)) $(if $(_TEST_DB_SEEDED),_TEST_DB_SEEDED=1) \
        $(if $(FILES),FILES=$(FILES)) $(if $(FILTER),FILTER=$(FILTER)) \
        $(if $(DETAILS),DETAILS=$(DETAILS)) $(if $(SUITES),SUITES=$(SUITES))
```

**Why only leaf targets seed:**
- Aggregators don't run tests — they orchestrate. Seeding is a test execution concern.
- A leaf target is the narrowest possible entry point. Whether you call `make test` (which calls `test-unit` which seeds) or `make test-backend-unit` directly (which calls `test-unit` which seeds), the seed always triggers at the right level.
- This avoids double-seeding: the aggregator doesn't seed, and the second leaf sees `_TEST_DB_SEEDED=1` from the first leaf.

**Why not a file?** A sentinel file (`/tmp/.test-seed-*`) persists after Ctrl+C, `kill -9`, OOM kills, or terminal crashes. The next test run would see the stale file and skip seeding, running against a database that may be half-seeded or in a dirty state from the interrupted run. An environment variable dies when the process tree dies — exactly the behavior we want.

### Suite-Scoped Seed Data

Each test suite must have its own seed data, and suites must not interfere with each other's data.

**Rules:**

1. **Each suite owns its data** — seed files create entities that belong to that suite and no other
2. **Suites never read, modify, or depend on another suite's seed data** — if two suites need a "user with admin role", each creates its own
3. **Use unique identifiers** — prefix entity names/emails with the suite name to avoid collisions (e.g., `auth-suite-user-1@test.com`, `billing-suite-user-1@test.com`)
4. **Seed files are deterministic** — running the seed twice produces the same state (use upserts or check-before-insert)

```typescript
// seed/auth-suite.ts — only auth tests use this data
export async function seedAuthSuite(db: DataSource) {
  const org = await db.getRepository(Organization).save({
    name: 'auth-suite-org',
    // ...
  });
  const user = await db.getRepository(User).save({
    firstName: 'auth-suite',
    lastName: 'user-1',
    email: 'auth-suite-user-1@test.com',
    organizationId: org.id,
    // ...
  });
  // ... more entities specific to auth tests
}
```

### Self-Contained Mutating Tests

Tests that **mutate or delete entities** must be fully self-contained — they create their own data, mutate it, assert on it, and clean up. They must never rely on shared seed data for the entities they modify.

**Rules:**

1. **Create before mutate** — if a test deletes a user, it creates that user first within the test
2. **Clean up after mutate** — use `beforeEach`/`afterEach` or transaction rollbacks to undo mutations
3. **Never mutate seed data** — seed data is read-only reference data; mutations go against test-created entities
4. **Transaction wrapping** — prefer wrapping mutating tests in a transaction that rolls back:

```typescript
describe('UserService - delete', () => {
  let testUser: User;

  beforeEach(async () => {
    // Create test-specific data — not shared seed data
    testUser = await userRepo.save({
      firstName: 'delete-test',
      lastName: 'user',
      email: 'delete-test-user@test.com',
    });
  });

  afterEach(async () => {
    // Clean up in case test didn't delete
    await userRepo.delete({ email: 'delete-test-user@test.com' });
  });

  it('should soft-delete a user', async () => {
    await userService.delete(testUser.id);
    const found = await userRepo.findOne({ where: { id: testUser.id } });
    expect(found.deletedAt).not.toBeNull();
  });
});
```

### Seeding Summary

| Principle | Rule |
|-----------|------|
| Seed only in leaf targets | Only targets that run test frameworks have `_seed-test-db` prerequisite — aggregators never seed |
| Seed once per invocation | In-memory env var (`_TEST_DB_SEEDED`) — first leaf seeds, rest skip |
| Any entry point works | Whether called from root, service, or directly — the leaf always checks and seeds if needed |
| Cancellation resets state | Environment variable dies with the process tree — next run always re-seeds |
| Suite-scoped data | Each suite owns its seed data, uses unique identifiers, never touches other suites' data |
| Self-contained mutations | Tests that mutate/delete create their own entities and clean up after themselves |
| Seed data is read-only | Shared seed data is for reading/asserting — never modified by tests |

---

## Test Structure

### Arrange-Act-Assert (AAA) Pattern

```python
def test_user_registration_sends_welcome_email():
    """Test that registering a user sends a welcome email."""
    # Arrange
    email = "newuser@example.com"
    password = "SecurePass123!"

    # Act
    user = register_user(email, password)

    # Assert
    assert_email_sent_to(email, subject="Welcome")
```

### Test Naming

Names should describe behavior being tested:

```python
# Good - describes behavior
def test_user_registration_sends_welcome_email():
def test_free_tier_user_limited_to_3_repositories():
def test_parse_version_raises_on_invalid_format():

# Bad - unclear
def test_user():
def test_repos():
def test_version():
```

---

## Test Fixtures

### Composable Fixtures

```python
@pytest.fixture
def db_session():
    """Provide a database session for testing."""
    session = TestSessionLocal()
    try:
        yield session
    finally:
        session.rollback()
        session.close()

@pytest.fixture
def sample_user(db_session):
    """Create a sample user for testing."""
    user = User(email="test@example.com", name="Test User")
    db_session.add(user)
    db_session.commit()
    return user

@pytest.fixture
def sample_repository(db_session, sample_user):
    """Create a sample repository for testing."""
    repo = Repository(name="test-repo", owner_id=sample_user.id)
    db_session.add(repo)
    db_session.commit()
    return repo

# Test using fixtures
def test_scan_repository(sample_repository):
    result = scan_repository(sample_repository.id)
    assert result.status == "completed"
```

### Async Fixtures

```python
@pytest.fixture
async def async_db_session():
    """Provide async database session for testing."""
    async with AsyncSessionLocal() as session:
        yield session
        await session.rollback()

@pytest.fixture
async def sample_user(async_db_session):
    """Create sample user with async session."""
    user = User(email="test@example.com")
    async_db_session.add(user)
    await async_db_session.commit()
    await async_db_session.refresh(user)
    return user
```

---

## Factories

Use factories for complex objects:

```python
class UserFactory:
    @staticmethod
    def create(
        email: str = "john.doe@example.com",
        name: str = "John Doe",
        account_tier: str = "free"
    ) -> User:
        return User(
            email=email,
            name=name,
            account_tier=account_tier,
            password_hash=hash_password("SecurePassword123!")
        )

class RepositoryFactory:
    @staticmethod
    def create(
        name: str = "test-repo",
        owner: User | None = None,
        is_private: bool = False
    ) -> Repository:
        return Repository(
            name=name,
            owner_id=owner.id if owner else None,
            is_private=is_private
        )

# Usage
def test_free_tier_user_limited_to_3_repositories():
    """Test that free tier users can only create 3 repositories."""
    user = UserFactory.create(account_tier="free")

    # Create 3 repositories - should succeed
    for i in range(3):
        repo = create_repository(user, name=f"repo-{i}")
        assert repo is not None

    # Fourth repository should fail
    with pytest.raises(RepositoryLimitExceeded):
        create_repository(user, name="repo-4")
```

---

## Mocking

### Mock External Dependencies

```python
from unittest.mock import Mock, patch, AsyncMock

def test_fetch_npm_package_handles_timeout():
    """Test that npm fetch handles timeout gracefully."""
    with patch('httpx.AsyncClient.get') as mock_get:
        mock_get.side_effect = httpx.TimeoutException("Request timed out")

        with pytest.raises(RegistryTimeoutError):
            await fetch_npm_package("express")

def test_send_welcome_email_called_with_correct_params():
    """Test that welcome email is sent with correct parameters."""
    with patch('app.services.email.send_email') as mock_send:
        register_user("user@example.com", "password")

        mock_send.assert_called_once_with(
            to="user@example.com",
            subject="Welcome",
            template="welcome"
        )
```

### Async Mocking

```python
async def test_fetch_package_info():
    """Test package info fetching."""
    mock_response = AsyncMock()
    mock_response.json.return_value = {"name": "express", "version": "4.18.0"}

    with patch('httpx.AsyncClient.get', return_value=mock_response):
        result = await fetch_package_info("express")
        assert result["version"] == "4.18.0"
```

### What to Mock

| Mock | Don't Mock |
|------|------------|
| External APIs | Your own code under test |
| Database (for unit tests) | Standard library |
| File system (for unit tests) | Simple utilities |
| Time/dates | Data structures |
| Random numbers | |

---

## Test Types

### Unit Tests

Test individual functions/methods in isolation:

```python
# Pure function - no mocking needed
def test_parse_semantic_version():
    result = parse_semantic_version("1.2.3")
    assert result == (1, 2, 3)

def test_parse_semantic_version_with_prerelease():
    result = parse_semantic_version("1.2.3-beta.1")
    assert result == (1, 2, 3, "beta.1")
```

### Integration Tests

Test components working together:

```python
async def test_user_can_create_and_scan_repository(db_session, sample_user):
    """Integration test for repository creation and scanning."""
    # Create repository
    repo = await create_repository(db_session, sample_user, "test-repo")
    assert repo.id is not None

    # Scan repository
    scan_result = await scan_repository(db_session, repo.id)
    assert scan_result.status == "completed"

    # Verify dependencies found
    deps = await get_repository_dependencies(db_session, repo.id)
    assert len(deps) > 0
```

### API Tests

Test HTTP endpoints:

```python
from fastapi.testclient import TestClient

def test_create_user_endpoint(client: TestClient):
    response = client.post("/api/v1/users", json={
        "email": "new@example.com",
        "password": "SecurePass123!"
    })

    assert response.status_code == 201
    assert response.json()["email"] == "new@example.com"

def test_create_user_with_existing_email_returns_409(client: TestClient, sample_user):
    response = client.post("/api/v1/users", json={
        "email": sample_user.email,
        "password": "SecurePass123!"
    })

    assert response.status_code == 409
```

---

## Test Organization

Mirror source structure:

```
backend/
├── app/
│   ├── services/
│   │   └── user_service.py
│   ├── api/
│   │   └── v1/
│   │       └── users.py
│   └── models/
│       └── user.py
└── tests/
    ├── conftest.py          # Shared fixtures
    ├── test_services/
    │   └── test_user_service.py
    ├── test_api/
    │   └── test_users.py
    └── test_models/
        └── test_user.py
```

---

## Test Coverage

### Coverage Requirements

- Minimum: 80% line coverage (configured in PROJECT.yaml `testing.min_coverage`)
- Focus on: Business logic, error paths, edge cases
- Skip: Boilerplate, simple getters/setters

### Running with Coverage

```bash
# Run with coverage
make test-cov

# Or with docker compose directly (when Docker is present)
docker compose run --rm backend pytest --cov=app --cov-report=term-missing --cov-report=html
```

---

## Common Patterns

### Testing Exceptions

```python
def test_parse_version_raises_on_invalid_format():
    with pytest.raises(InvalidVersionError) as exc_info:
        parse_version("not-a-version")

    assert "Invalid version format" in str(exc_info.value)

def test_get_user_raises_not_found():
    with pytest.raises(UserNotFoundError) as exc_info:
        get_user(99999)

    assert exc_info.value.user_id == 99999
```

### Parametrized Tests

```python
@pytest.mark.parametrize("version,expected", [
    ("1.0.0", (1, 0, 0)),
    ("2.1.3", (2, 1, 3)),
    ("0.0.1", (0, 0, 1)),
    ("10.20.30", (10, 20, 30)),
])
def test_parse_semantic_version(version, expected):
    assert parse_semantic_version(version) == expected

@pytest.mark.parametrize("invalid_version", [
    "1.0",
    "1",
    "a.b.c",
    "",
    "1.0.0.0",
])
def test_parse_semantic_version_invalid(invalid_version):
    with pytest.raises(InvalidVersionError):
        parse_semantic_version(invalid_version)
```

### Testing Time-Dependent Code

```python
from freezegun import freeze_time

@freeze_time("2024-01-15 12:00:00")
def test_token_expiration():
    token = create_access_token(user_id=1, expires_in_hours=24)

    # Token should be valid now
    assert is_token_valid(token)

@freeze_time("2024-01-16 13:00:00")
def test_token_expired():
    # Same token should be expired 25 hours later
    assert not is_token_valid(token)
```

---

## Checklist

Before committing tests:

- [ ] Tests follow AAA pattern
- [ ] Test names describe behavior
- [ ] One logical assertion per test
- [ ] External dependencies mocked
- [ ] No tests depend on execution order
- [ ] All tests pass in isolation
- [ ] Coverage >= 80%
- [ ] Suite seed data is scoped — unique identifiers, no cross-suite dependencies
- [ ] Mutating tests are self-contained — create own data, clean up after
- [ ] Tests run via `make test` targets, never by calling frameworks directly
- [ ] Runner scripts exit 0 in JSON mode, native exit code otherwise
- [ ] Runner scripts support `--suites`, `--files`, `--filter`, `--details`, `--raw`
- [ ] JSON output follows the standard contract (status, failures, warning_details)
- [ ] Aggregator targets use `TEST_TARGETS` variable + `run-aggregate.sh`

See also: [Makefile Best Practices](makefile.md) — target naming, delegation pattern, AI auto-detection, JSON output implementation

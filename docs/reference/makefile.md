# Makefile Best Practices

Standardized approach to project automation using hierarchical Makefiles.

---

## Philosophy

- **Root Makefile**: Orchestrates the entire project — delegates to service Makefiles for anything service-specific
- **Service Makefiles**: Each component defined in `PROJECT.yaml` gets its own Makefile that owns its targets and knows how to run its tools
- **Helper scripts**: Complex logic (JSON transformation, test runners, database seeding, interactive prompts) lives in `scripts/`
- **Abstraction over implementation**: Callers never need to know which tool runs under the hood — they call `make test-<service>-unit` and get results, whether it's Jest, pytest, Playwright, Newman, or anything else
- **Convention over configuration**: Standard target names across all projects

---

## Service Names Come from PROJECT.yaml

The `<service>` placeholder used throughout this document maps to the `path` field of each entry in `components[]`:

```yaml
# PROJECT.yaml
components:
  - name: "Backend API"
    path: "backend"           # → make test-backend, make lint-backend
    language: "typescript"
  - name: "Frontend App"
    path: "frontend"          # → make test-frontend, make lint-frontend
    language: "typescript"
  - name: "AI Service"
    path: "ai"                # → make test-ai, make lint-ai
    language: "python"
```

The number and names of services vary per project. A project with only a `backend` component has `test-backend` but no `test-frontend`. A project with `api`, `web`, and `worker` components gets `test-api`, `test-web`, `test-worker`.

**When generating Makefiles** (via `/makefile-init`), read `components[].path` to determine which service targets to create. Do not hardcode service names.

---

## Target Naming Convention

### Delegation Pattern

The root Makefile exposes two kinds of targets:

1. **Project-wide targets** — run directly (e.g., `up`, `down`, `build`, `clean`)
2. **Delegating targets** — call into service Makefiles using a consistent naming scheme

### Naming Scheme

```
<action>                              # Project-wide (all services)
<action>-<service>                    # All sub-actions for a service
<action>-<service>-<subtype>          # Specific sub-action for a service
```

Where `<service>` is the `path` value from `components[]` in PROJECT.yaml.

**Example** (for a project with `backend` and `frontend` components):

```
make test                             # All tests (all services)
make test-backend                     # All backend tests (unit + e2e)
make test-backend-unit                # Backend unit tests only
make test-backend-e2e                 # Backend E2E tests only
make test-frontend                    # All frontend tests
make test-frontend-e2e                # Frontend Playwright E2E tests

make lint                             # Lint all services
make lint-backend                     # Lint backend only
make lint-frontend                    # Lint frontend only

make logs-backend                     # Backend logs
make shell-backend                    # Shell into backend container
```

**Example** (for a project with `api`, `web`, `worker` components):

```
make test                             # All tests
make test-api                         # API service tests
make test-api-unit                    # API unit tests only
make test-web-e2e                     # Web Playwright E2E tests
make lint-worker                      # Lint worker service
```

### How Delegation Works

Root targets delegate by calling `$(MAKE) -C <service> <target>`:

```makefile
# Root Makefile — delegates to service Makefile
test-<service>: ## Run all <service> tests
	@$(MAKE) --no-print-directory -C <service> test $(_PASS)

test-<service>-unit: ## Run <service> unit tests
	@$(MAKE) --no-print-directory -C <service> test-unit $(_PASS)
```

```makefile
# <service>/Makefile — owns the actual implementation
test-unit: ## Run unit tests
ifdef FORMAT
	@../scripts/test-jest.sh --target test-<service>-unit $(_SCRIPT_FLAGS)
else
	@echo "Running unit tests..."
	npx jest $(FILES) $(if $(FILTER),-t "$(FILTER)")
endif
```

The service Makefile knows the tool. The root Makefile and the caller don't.

---

## Project Structure

```
project/
├── PROJECT.yaml                # Defines components, services, tech stack
├── Makefile                    # Root orchestrator
├── scripts/
│   ├── run-jest.sh             # Jest runner → standard JSON
│   ├── run-playwright.sh       # Playwright runner → standard JSON
│   ├── run-newman.sh           # Newman runner → standard JSON
│   ├── run-pytest.sh           # pytest runner → standard JSON
│   ├── run-bats.sh             # BATS runner → standard JSON
│   ├── run-aggregate.sh        # Aggregates sub-target JSON results
│   ├── status.sh               # Rich service status display
│   └── db-reset.sh             # Interactive DB reset
├── <service-1>/
│   └── Makefile                # Service targets (test, lint, etc.)
├── <service-2>/
│   └── Makefile                # Service targets (test, lint, etc.)
└── <service-N>/
    └── Makefile                # Service targets (optional)
```

Each directory listed in `components[].path` contains its own Makefile. Only create runner scripts for test frameworks actually used by the project (e.g., skip `run-playwright.sh` if no component uses Playwright).

---

## Test Abstraction

**The Makefile is an abstraction layer.** Neither the developer nor the LLM needs to know:
- Which test framework runs (Jest, pytest, Playwright, Newman, BATS)
- Whether tests run natively or inside a Docker container
- What CLI flags the framework needs
- How to parse the framework's output format

They just call the target and get results.

### What the Abstraction Hides

| What the caller does | What actually happens (varies by project) |
|---------------------|------------------------------------------|
| `make test-<service>-unit` | Framework runs (Jest, pytest, etc.), output parsed by runner script into standard JSON |
| `make test-<service>-e2e` | E2E framework runs (Playwright, Newman, etc.), output parsed into standard JSON |
| `make test-<service>` | Sub-targets run, results aggregated by `run-aggregate.sh` |
| `make test` | All service aggregators run, results aggregated again at root level |

### Runner Scripts

Each test framework has a dedicated runner script in `scripts/` that:

1. Accepts standard flags (`--target`, `--files`, `--filter`, `--suites`, `--details`, `--raw`)
2. Translates them into framework-specific CLI args
3. Runs the framework silently, capturing raw output to a temp file
4. Parses framework-native output into the standard JSON contract
5. Returns the standard JSON on stdout
6. **Exits 0 in JSON mode** — the `status` field carries pass/fail, not the exit code (prevents Make from aborting mid-aggregation)
7. **Exits with the framework's native exit code in human mode** — so developers see expected red/green terminal behavior

When `--raw` is passed, the script runs the framework and passes through raw output without JSON transformation.

Only include runner scripts for frameworks your project actually uses:

```
scripts/
├── run-jest.sh            # Jest → standard JSON (TypeScript/JavaScript)
├── run-pytest.sh          # pytest → standard JSON (Python)
├── run-playwright.sh      # Playwright → standard JSON (E2E)
├── run-newman.sh          # Newman → standard JSON (API collections)
├── run-bats.sh            # BATS → standard JSON (bash/shell)
├── run-aggregate.sh       # Aggregates sub-target JSON results
```

If tests need to run inside a Docker container (e.g., service tests that need the DB), the service Makefile handles that — the runner script doesn't care. The Makefile recipe uses `docker compose run --rm <service>` to execute in a temporary, self-removing container.

See: [Testing Best Practices](testing.md) for the full JSON contract, runner script contract, seeding strategy, and data isolation rules.

---

## LLM-Optimized JSON Output

### Design Principle

When `FORMAT=json` is set, the Makefile produces **pure JSON on stdout** — no directory paths, no make banners, no ANSI colors, no framework progress bars. LLMs consume structured data; mixing prose into a JSON stream forces the LLM to parse around noise, wastes tokens, and risks malformed extraction.

### AI Auto-Detection

AI coding assistants are detected automatically so they get clean JSON output without passing `FORMAT=json` on every call. The Makefile checks for known environment variables set by each tool:

| Tool | Environment Variable | Set By |
|------|---------------------|--------|
| Claude Code | `CLAUDECODE=1` | Automatically by Claude Code CLI |
| Cursor | `CURSOR_SESSION_ID` | Automatically by Cursor IDE terminal |
| Codex | `CODEX_CLI=1` | Automatically by OpenAI Codex CLI |
| Gemini | `GEMINI_API_KEY` | User-configured for Gemini Code Assist |
| Generic fallback | `AI_AGENT=1` | Set manually for any unlisted AI tool |

**Place this block near the top of the root Makefile, before any `ifdef FORMAT` logic:**

```makefile
# ============================================
# AI Auto-Detection — clean JSON for LLMs
# ============================================
# Detect known AI coding assistants and force JSON output.
# Humans get normal colored output. AI gets pure JSON, no noise.
# Override with FORMAT=human if an AI caller wants human output.
ifdef CLAUDECODE
  FORMAT ?= json
endif
ifdef CURSOR_SESSION_ID
  FORMAT ?= json
endif
ifdef CODEX_CLI
  FORMAT ?= json
endif
ifdef GEMINI_API_KEY
  FORMAT ?= json
endif
ifdef AI_AGENT
  FORMAT ?= json
endif

# When FORMAT is set, suppress all directory-change noise globally
ifdef FORMAT
  MAKEFLAGS += --no-print-directory
endif
```

**How it works:**
- `FORMAT ?=` means "set only if not already set" — explicit `FORMAT=human` overrides auto-detection
- `MAKEFLAGS += --no-print-directory` propagates to all sub-make calls automatically, so you don't need `--no-print-directory` on individual `$(MAKE)` calls when FORMAT is active
- The `AI_AGENT=1` fallback lets any unlisted AI tool opt in by setting one env var
- **Humans are never affected** — without the env var, FORMAT stays unset and output is normal

**Important:** Copy this block into each service Makefile too (or `include` a shared `ai-detect.mk`), so direct calls like `make -C backend test` also auto-detect.

### Usage

```bash
# AI callers — FORMAT=json is automatic, just call the target
make test
make test-<service>-unit
make test-<service> SUITES="auth,users"

# Human callers — normal colored output by default
make test
make test FORMAT=json              # Opt in to JSON explicitly

# Override auto-detection (AI caller wants human output)
make test FORMAT=human
```

### SUITES — Focused Test Runs

The `SUITES` flag lets callers run a subset of test suites within a service, avoiding full test runs when only specific areas are relevant:

```bash
make test-<service> SUITES="auth,users"         # Run only auth + users suites
make test-<service>-unit SUITES="auth"           # Single suite, unit tests only
make test-<service> SUITES="auth" FILTER="login" # Suite + name filter combined
make test-<service>                               # All suites (default)
```

Runner scripts translate `--suites` into framework-specific targeting:

| Framework | `--suites "auth,users"` becomes |
|-----------|--------------------------------|
| pytest | `-k "auth or users"` or path-based `tests/auth tests/users` |
| Jest | `--testPathPattern="(auth\|users)"` |
| Playwright | `--project="auth" --project="users"` |
| Newman | Collection folder filtering |
| BATS | File matching `*auth* *users*` |

### Suppressing Make Noise

**Root Makefile** — define a `_PASS` variable to forward all args. When AI auto-detection sets FORMAT, `MAKEFLAGS` already includes `--no-print-directory`, so sub-make calls are clean automatically:

```makefile
# Pass-through args for test sub-make calls
_PASS = $(if $(FORMAT),FORMAT=$(FORMAT)) $(if $(FILES),FILES=$(FILES)) \
        $(if $(FILTER),FILTER=$(FILTER)) $(if $(DETAILS),DETAILS=$(DETAILS)) \
        $(if $(SUITES),SUITES=$(SUITES))

test-<service>: ## Run all <service> tests
##   FORMAT=json          Output results as JSON
##   SUITES="auth,users"  Run specific test suites
	@$(MAKE) -C <service> test $(_PASS)
```

**Service Makefiles** — define `SCRIPTS_DIR`, `_PASS` (for sub-make calls), and `_SCRIPT_FLAGS` (for runner scripts):

```makefile
SCRIPTS_DIR := ../scripts

# Build script flags from make variables
_SCRIPT_FLAGS = $(if $(FILES),--files "$(FILES)") \
                $(if $(FILTER),--filter "$(FILTER)") \
                $(if $(SUITES),--suites "$(SUITES)") \
                $(if $(DETAILS),--details)

# Pass-through args for sub-make calls
_PASS = $(if $(FORMAT),FORMAT=$(FORMAT)) $(if $(FILES),FILES=$(FILES)) \
        $(if $(FILTER),FILTER=$(FILTER)) $(if $(DETAILS),DETAILS=$(DETAILS)) \
        $(if $(SUITES),SUITES=$(SUITES))
```

**`ifdef FORMAT` branching** — when FORMAT is set, call the runner script (which outputs JSON). When `FORMAT=raw`, pass `--raw` for unprocessed framework output. When FORMAT is unset, run the tool directly with human-friendly output:

```makefile
test-unit: ## Run unit tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
ifdef FORMAT
ifeq ($(FORMAT),raw)
	@$(SCRIPTS_DIR)/run-<runner>.sh --target test-<service>-unit --raw $(_SCRIPT_FLAGS)
else
	@$(SCRIPTS_DIR)/run-<runner>.sh --target test-<service>-unit $(_SCRIPT_FLAGS)
endif
else
	@echo "Running unit tests..."
	<framework-command> $(FILES) $(if $(FILTER),<filter-flag> "$(FILTER)")
endif
```

### Why `ifdef FORMAT` Instead of `ifeq`

We use `ifdef FORMAT` (test for existence) rather than `ifeq ($(FORMAT),json)`:
- Simpler — any value of FORMAT triggers JSON mode (except `human` — see note below)
- Avoids whitespace gotchas with `ifeq` comparisons in Make
- Consistent pattern: set FORMAT to get JSON, omit it for human output

**Note on `FORMAT=human`:** If an AI caller passes `FORMAT=human` to override auto-detection, `ifdef FORMAT` still evaluates true. Runner scripts should check for `--format human` and output plain text. Alternatively, check explicitly:

```makefile
# If you need to distinguish human from json:
ifeq ($(FORMAT),human)
  # Human-friendly output (override for AI callers)
  _FORMAT_MODE = human
else ifdef FORMAT
  # JSON output (auto-detected or explicit)
  _FORMAT_MODE = json
endif
```

### JSON Contract — Leaf Targets

Leaf targets (run tests directly) return:

```json
{
  "version": 2,
  "target": "test-<service>-<type>",
  "status": "fail",
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
    "Slow test: user.service > bulk import (4.2s)"
  ]
}
```

**Version:** All V2 JSON includes `"version": 2`. If absent, consumers assume V1 (legacy). See: [Testing Best Practices — Contract Versioning](testing.md#contract-versioning) for the full V1 → V2 normalization table and migration path.

**Status logic:** `"pass"` when `failed == 0 AND skipped == 0`. Warnings do not affect status. See: [Testing Best Practices — Status Logic](testing.md#status-logic).

**FORMAT=raw:** When `FORMAT=raw` is passed, runner scripts output the framework's raw output without JSON transformation. Useful for debugging when JSON obscures the real error.

With `DETAILS=1`, adds timing stats and per-suite breakdown:

```json
{
  "version": 2,
  "target": "test-<service>-<type>",
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
        { "test": "should reject expired tokens", "status": "failed", "duration_ms": 12 }
      ]
    }
  ]
}
```

### JSON Contract — Aggregator Targets

Aggregator targets (combine sub-targets) wrap child results in a `targets` array. Each child includes the full contract:

```json
{
  "version": 2,
  "target": "test-<service>",
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
      "target": "test-<service>-unit",
      "status": "fail",
      "suites": 12,
      "tests": 87,
      "passed": 85,
      "failed": 2,
      "skipped": 0,
      "warnings": 1,
      "duration_ms": 4523,
      "failures": [ "..." ],
      "warning_details": [ "..." ]
    },
    {
      "target": "test-<service>-e2e",
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

### JSON Fields by Target Category

| Target | Category | Required | JSON fields |
|--------|----------|----------|-------------|
| `up` | service | yes | `services` |
| `down` | service | yes | `services_stopped` |
| `status` | service | yes | `services` |
| `test` | testing | yes | `status, passed, failed, skipped, warnings, duration_ms, failures, warning_details` |
| `test-*-e2e` | testing | no | `status, passed, failed, skipped, warnings, duration_ms, failures, warning_details` |
| `lint` | quality | yes | `errors, warnings, files_checked` |
| `format` | quality | yes | `files_changed` |
| `typecheck` | quality | yes | `errors, warnings` |
| `migrate` | database | no | `migrations_applied, current_head` |
| `build` | build | no | `image_tag, duration_ms` |
| `clean` | lifecycle | yes | `items_removed` |
| `targets` | meta | yes | `targets[]` |

### Aggregation Implementation

Aggregator targets use a `TEST_TARGETS` variable and delegate to `run-aggregate.sh`:

```makefile
# In a service Makefile — aggregates unit + e2e for this service
TEST_TARGETS := test-unit test-e2e

test: ## Run all tests (unit + e2e)
##   FORMAT=json          Output results as JSON
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include timing breakdown
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test-<service> \
		--targets "$(TEST_TARGETS)" $(_PASS)
else
	$(MAKE) test-unit
	$(MAKE) test-e2e
endif
```

Adding a new sub-target is one line: `TEST_TARGETS := test-unit test-e2e test-api`

The `run-aggregate.sh` script:
- Calls each sub-target via `make <target> FORMAT=json`
- Collects and sums `suites`, `tests`, `passed`, `failed`, `skipped`, `warnings` across all children
- Merges all `failures` and `warning_details` arrays
- Sets `status` to `"fail"` if any child has `status: "fail"`
- Includes each child's full JSON as an entry in the `targets` array
- With `DETAILS=1`, passes it through to children and computes aggregate `timing` stats
- **Exits 0** — the `status` field carries pass/fail, consistent with runner script exit behavior

---

## Self-Documenting Help

All Makefiles use a self-documenting help pattern. Targets are annotated with `##` comments and the help recipe parses them with `awk`.

### How It Works

**Targets** use `## description` after the target declaration:

```makefile
up: ## Start all services
down: ## Stop all services
test: ## Run all tests
```

**Arguments** use `##   ` (two hashes + 3 spaces) on lines immediately following a target. These render indented under the target in the help output:

```makefile
test: ## Run all tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   DETAILS=1            Include per-test durations and timing stats
```

### Help Recipe

Every Makefile must use this `awk`-based help recipe:

```makefile
help: ## Show this help message
	@awk '/^[a-zA-Z0-9_-]+:.*## .*$$/ { \
		target=$$0; sub(/:.*## /,"\t",target); \
		split(target,a,"\t"); \
		printf "  \033[36m%-24s\033[0m %s\n", a[1], a[2]; \
		next \
	} /^##   / { \
		line=$$0; sub(/^##   /,"",line); \
		printf "  %-24s   \033[33m%s\033[0m\n", "", line; \
	}' $(MAKEFILE_LIST)
```

**Output format:**
- Target names in **cyan**
- Argument lines in **yellow**, indented under their target
- Targets without `##` are hidden from help (internal/private targets)

### Example Output

```
  test                     Run all tests
                              FORMAT=json          Output results as JSON
                              FILES="a.spec.ts"    Run specific test files
                              FILTER="pattern"     Filter tests by name pattern
  lint                     Run all linters
  migrate-new              Create new migration
                              NAME="description"   Migration name (required)
```

### Rules

1. **Target pattern**: `^[a-zA-Z0-9_-]+:.*## .*$` — include digits in the character class (targets like `test-e2e` need this)
2. **Argument pattern**: `^##   ` — exactly two hashes followed by three spaces
3. **Argument lines must immediately follow** their target line (no blank lines between)
4. **Alignment**: Use column 26 for argument descriptions (pad `ARG=value` with spaces)
5. **Avoid the old grep pattern**: `grep -E '^[a-zA-Z_-]+:.*?## .*$$'` — this misses targets with digits and doesn't support argument annotations

---

## Standard Targets

All projects should have these targets at the root level. Replace `<service>` with each component's `path` from PROJECT.yaml:

| Target | Purpose | Delegates? |
|--------|---------|------------|
| `help` | Show available commands (default) | No |
| `up` | Start services | No |
| `down` | Stop services | No |
| `status` | Show service status | No |
| `logs` | Tail all logs | No |
| `logs-<service>` | Tail service logs | No |
| `test` | Run all tests | Yes — aggregates `test-<service>` |
| `test-<service>` | Run all tests for a service | Yes — aggregates `test-<service>-<type>` |
| `test-<service>-<type>` | Run specific test type | Yes — calls service leaf target |
| `lint` | Run all linters | Yes |
| `lint-<service>` | Lint a specific service | Yes |
| `format` | Format all code | Yes |
| `format-<service>` | Format a specific service | Yes |
| `typecheck` | Type check all code | Yes |
| `migrate` | Run database migrations | Yes |
| `migrate-new` | Create new migration | Yes |
| `db-seed` | Seed database | Yes |
| `db-reset` | Reset database (destructive) | No — runs `scripts/db-reset.sh` |
| `build` | Build Docker images | No |
| `clean` | Remove containers/volumes | No |
| `shell-<service>` | Shell into service container | No |

Not every project has every target. A project without a database omits `migrate`, `db-seed`, `db-reset`. A project with a single component omits per-service suffixes if there's no ambiguity (but the pattern still works with one service).

---

## Root Makefile

The root Makefile orchestrates all components. The example below shows a project with two components (`backend` and `frontend`). Adapt the service-specific targets to match your `components[]`:

```makefile
# Project Makefile
# Usage: make <target>
#
# Service targets are generated from components[] in PROJECT.yaml.
# Each <service> below corresponds to a components[].path value.

.PHONY: help up down status logs test lint format typecheck build clean

.DEFAULT_GOAL := help

# ============================================
# AI Auto-Detection — clean JSON for LLMs
# ============================================
ifdef CLAUDECODE
  FORMAT ?= json
endif
ifdef CURSOR_SESSION_ID
  FORMAT ?= json
endif
ifdef CODEX_CLI
  FORMAT ?= json
endif
ifdef GEMINI_API_KEY
  FORMAT ?= json
endif
ifdef AI_AGENT
  FORMAT ?= json
endif

ifdef FORMAT
  MAKEFLAGS += --no-print-directory
endif

# Script directory
SCRIPTS_DIR := scripts

# Pass-through args for sub-make calls
_PASS = $(if $(FORMAT),FORMAT=$(FORMAT)) $(if $(FILES),FILES=$(FILES)) \
        $(if $(FILTER),FILTER=$(FILTER)) $(if $(DETAILS),DETAILS=$(DETAILS)) \
        $(if $(SUITES),SUITES=$(SUITES))

# ============================================
# Help (self-documenting with argument support)
# ============================================
help: ## Show this help message
	@awk '/^[a-zA-Z0-9_-]+:.*## .*$$/ { \
		target=$$0; sub(/:.*## /,"\t",target); \
		split(target,a,"\t"); \
		printf "  \033[36m%-24s\033[0m %s\n", a[1], a[2]; \
		next \
	} /^##   / { \
		line=$$0; sub(/^##   /,"",line); \
		printf "  %-24s   \033[33m%s\033[0m\n", "", line; \
	}' $(MAKEFILE_LIST)

# ============================================
# Services (project-wide — run directly)
# ============================================
up: ## Start all services
	@docker compose up -d

down: ## Stop all services
	@docker compose down

status: ## Show service status
	@./scripts/status.sh

logs: ## Tail all logs
	@docker compose logs -f

# One logs-<service> target per component
logs-backend: ## Tail backend logs
	@docker compose logs -f backend

logs-frontend: ## Tail frontend logs
	@docker compose logs -f frontend

# ============================================
# Testing — delegates to service Makefiles
# ============================================
#
# Root `test` aggregates across all components.
# TEST_TARGETS lists sub-targets — add/remove to match your components[].
#
TEST_TARGETS := test-backend test-frontend

test: ## Run all tests (all services)
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test \
		--targets "$(TEST_TARGETS)" $(_PASS)
else
	$(MAKE) -C backend test $(_PASS)
	$(MAKE) -C frontend test $(_PASS)
endif

test-backend: ## Run all backend tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
	@$(MAKE) -C backend test $(_PASS)

test-backend-unit: ## Run backend unit tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
	@$(MAKE) -C backend test-unit $(_PASS)

test-backend-e2e: ## Run backend E2E tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
	@$(MAKE) -C backend test-e2e $(_PASS)

test-frontend: ## Run all frontend tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
	@$(MAKE) -C frontend test $(_PASS)

test-frontend-unit: ## Run frontend unit tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
	@$(MAKE) -C frontend test-unit $(_PASS)

test-frontend-e2e: ## Run frontend E2E tests
##   FORMAT=json          Output results as JSON
##   FILES="a.spec.ts"    Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
	@$(MAKE) -C frontend test-e2e $(_PASS)

# ============================================
# Code Quality — delegates to service Makefiles
# ============================================
lint: ## Run linters (all services)
	$(MAKE) -C backend lint
	$(MAKE) -C frontend lint

format: ## Format all code
	$(MAKE) -C backend format
	$(MAKE) -C frontend format

typecheck: ## Run type checks
	$(MAKE) -C frontend typecheck

# ============================================
# Database
# ============================================
migrate: ## Run database migrations
	@$(MAKE) -C backend migrate

migrate-new: ## Create new migration
##   NAME="description"   Migration name (required)
	@$(MAKE) -C backend migrate-new NAME="$(NAME)"

db-seed: ## Seed database
	@$(MAKE) -C backend db-seed

db-reset: ## Reset database (destructive)
	@./scripts/db-reset.sh

# ============================================
# Build
# ============================================
build: ## Build all Docker images
	@docker compose build

clean: ## Remove containers/volumes (destructive)
	@docker compose down -v --remove-orphans

# ============================================
# CI Targets
# ============================================
ci-lint: lint ## CI lint target
ci-test: test ## CI test target
ci-typecheck: typecheck ## CI typecheck target
```

**Adapting to your project:**
- Add a `test-<service>` / `test-<service>-unit` / `test-<service>-e2e` block for each component in `components[]`
- Add the component to the `test` aggregator's tmpdir/JSON block
- Add `lint-<service>`, `format-<service>` delegations as needed
- Database targets delegate to whichever component owns the migration tool (configured in `databases[].migrations.service` in PROJECT.yaml)
- `typecheck` delegates only to components that have a type checker (TypeScript, Pyright, etc.)

---

## Service Makefile Template

Each component directory gets a Makefile that owns the implementation details — it knows the framework, the flags, and the runner scripts. The `--target` value passed to runner scripts must match the root-level target name (e.g., `test-backend-unit`) so JSON output is traceable.

Adapt the template below to the component's language and test frameworks:

```makefile
# <service>/Makefile
#
# Replace <service> with this component's path from PROJECT.yaml.
# Replace <runner> with the appropriate test runner script (jest, pytest, playwright, etc.).
# Replace <framework-command> with the direct CLI command for human-mode output.

.PHONY: help test test-unit test-e2e test-cov lint lint-fix format format-check \
        typecheck migrate migrate-new migrate-down db-seed shell deps

.DEFAULT_GOAL := help

# ============================================
# AI Auto-Detection — clean JSON for LLMs
# ============================================
ifdef CLAUDECODE
  FORMAT ?= json
endif
ifdef CURSOR_SESSION_ID
  FORMAT ?= json
endif
ifdef CODEX_CLI
  FORMAT ?= json
endif
ifdef GEMINI_API_KEY
  FORMAT ?= json
endif
ifdef AI_AGENT
  FORMAT ?= json
endif

ifdef FORMAT
  MAKEFLAGS += --no-print-directory
endif

# Script directory
SCRIPTS_DIR := ../scripts

# Build script flags from make variables
_SCRIPT_FLAGS = $(if $(FILES),--files "$(FILES)") \
                $(if $(FILTER),--filter "$(FILTER)") \
                $(if $(SUITES),--suites "$(SUITES)") \
                $(if $(DETAILS),--details)

# Pass-through args for sub-make calls
_PASS = $(if $(FORMAT),FORMAT=$(FORMAT)) $(if $(FILES),FILES=$(FILES)) \
        $(if $(FILTER),FILTER=$(FILTER)) $(if $(DETAILS),DETAILS=$(DETAILS)) \
        $(if $(SUITES),SUITES=$(SUITES))

help: ## Show this help message
	@awk '/^[a-zA-Z0-9_-]+:.*## .*$$/ { \
		target=$$0; sub(/:.*## /,"\t",target); \
		split(target,a,"\t"); \
		printf "  \033[36m%-24s\033[0m %s\n", a[1], a[2]; \
		next \
	} /^##   / { \
		line=$$0; sub(/^##   /,"",line); \
		printf "  %-24s   \033[33m%s\033[0m\n", "", line; \
	}' $(MAKEFILE_LIST)

# ============================================
# Testing
# ============================================

TEST_TARGETS := test-unit test-e2e

test: ## Run all tests (unit + e2e)
##   FORMAT=json          Output results as JSON
##   FILES="file.spec.ts" Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
ifdef FORMAT
	@$(SCRIPTS_DIR)/run-aggregate.sh --target test-<service> \
		--targets "$(TEST_TARGETS)" $(_PASS)
else
	$(MAKE) test-unit
	$(MAKE) test-e2e
endif

test-unit: ## Run unit tests
##   FORMAT=json          Output results as JSON
##   FILES="file.spec.ts" Run specific test files
##   FILTER="pattern"     Filter tests by name pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
ifdef FORMAT
ifeq ($(FORMAT),raw)
	@$(SCRIPTS_DIR)/run-<runner>.sh --target test-<service>-unit --raw $(_SCRIPT_FLAGS)
else
	@$(SCRIPTS_DIR)/run-<runner>.sh --target test-<service>-unit $(_SCRIPT_FLAGS)
endif
else
	@echo "Running unit tests..."
	<framework-command> $(FILES) $(if $(FILTER),<filter-flag> "$(FILTER)")
endif

test-e2e: ## Run E2E tests
##   FORMAT=json          Output results as JSON
##   FILES="file.spec.ts" Run specific test files
##   FILTER="pattern"     Filter tests by name/grep pattern
##   SUITES="auth,users"  Run specific test suites
##   DETAILS=1            Include per-test durations and timing stats
ifdef FORMAT
ifeq ($(FORMAT),raw)
	@$(SCRIPTS_DIR)/run-<runner>.sh --target test-<service>-e2e --raw $(_SCRIPT_FLAGS)
else
	@$(SCRIPTS_DIR)/run-<runner>.sh --target test-<service>-e2e $(_SCRIPT_FLAGS)
endif
else
	@echo "Running E2E tests..."
	<e2e-framework-command> $(FILES) $(if $(FILTER),<filter-flag> "$(FILTER)")
endif

test-cov: ## Run tests with coverage
	@echo "Running tests with coverage..."
	<coverage-command>

# ============================================
# Code Quality
# ============================================

lint: ## Run linter
	@echo "Running linter..."
	<lint-command>

lint-fix: ## Run linter with auto-fix
	<lint-fix-command>

format: ## Format code
	<format-command>

format-check: ## Check formatting without changes
	<format-check-command>

typecheck: ## Run type checker
	<typecheck-command>

# ============================================
# Database (only in component that owns migrations)
# ============================================

migrate: ## Run database migrations
	@docker compose run --rm <service> <migrate-command>

migrate-new: ## Create new migration
##   NAME="description"   Migration name (required)
	@docker compose run --rm <service> <migrate-new-command> "$(NAME)"

migrate-down: ## Rollback last migration
	@docker compose run --rm <service> <migrate-down-command>

db-seed: ## Seed database
	@docker compose run --rm <service> <seed-command>

# ============================================
# Shell & Dependencies
# ============================================

shell: ## Shell into container
	@docker compose exec <service> /bin/bash

deps: ## Install dependencies
	@docker compose run --rm <service> <install-command>
```

**Concrete examples** of framework substitution:

| Placeholder | TypeScript/Jest | Python/pytest | Playwright |
|-------------|----------------|---------------|------------|
| `<runner>` | `jest` (→ `run-jest.sh`) | `pytest` (→ `run-pytest.sh`) | `playwright` (→ `run-playwright.sh`) |
| `<framework-command>` | `npx jest` | `pytest` | `npx playwright test` |
| `<filter-flag>` | `-t` | `-k` | `--grep` |
| `<lint-command>` | `npm run lint` | `ruff check .` | — |
| `<format-command>` | `npm run format` | `ruff format .` | — |
| `<typecheck-command>` | `npx tsc --noEmit` | `pyright app/` | — |
| `<migrate-command>` | `npm run migration:run` | `alembic upgrade head` | — |
| `<install-command>` | `npm install` | `uv pip sync requirements.txt` | — |

---

## Helper Scripts

### scripts/status.sh

Colored service status display. Adapt the service list to match `docker.services` or `components[]` in PROJECT.yaml:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

get_status() {
    local container=$1
    if docker ps --filter "name=$container" --filter "status=running" -q | grep -q .; then
        echo -e "${GREEN}RUNNING${NC}"
    elif docker ps -a --filter "name=$container" -q | grep -q .; then
        echo -e "${YELLOW}STOPPED${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
    fi
}

# Adapt this list to your project's services
PROJECT_NAME="${PROJECT_NAME:-$(basename "$(pwd)")}"

echo ""
echo "Service Status"
echo "=============="
# List each docker compose service here
for svc in $(docker compose config --services 2>/dev/null); do
    printf "%-12s %s\n" "${svc}:" "$(get_status "${PROJECT_NAME}-${svc}")"
done
echo ""
```

### scripts/db-reset.sh

Interactive database reset with confirmation prompt. Adapt the migration command to match `databases[].migrations.tool` in PROJECT.yaml:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "WARNING: This will destroy all data in the database!"
read -p "Are you sure? [y/N] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

docker compose down -v
docker compose up -d postgres   # Adapt to your DB service name
sleep 3
docker compose run --rm <service> <migrate-command>  # e.g., backend alembic upgrade head
echo "Database reset complete."
```

---

## Advanced Patterns

### Default Variables

```makefile
# Set defaults that can be overridden from the command line
DOCKER_COMPOSE ?= docker compose
TEST_ARGS ?= -v

test-<service>:
	@$(DOCKER_COMPOSE) run --rm <service> <test-command> $(TEST_ARGS)

# Override: make test-<service> TEST_ARGS="-v --tb=short"
```

### Conditional Targets

```makefile
# Only delegate if the service directory exists
lint-<service>:
	@test -d <service> && $(MAKE) -C <service> lint || true
```

### Including Other Makefiles

```makefile
# Include shared definitions
include common.mk

# Or conditionally
-include local.mk  # Dash means "don't error if missing"
```

### Parallel Execution

```bash
# Run independent targets in parallel
make -j4 lint-<service-1> lint-<service-2> typecheck
```

---

## CI Integration

```makefile
# CI-specific targets (no interactive prompts, machine-readable output)
ci-lint: lint ## CI lint target
ci-test: test ## CI test target
ci-typecheck: typecheck ## CI typecheck target

# Security scanning (CI only — adapt commands to your stack)
ci-security: ## Run security scans
	@docker compose run --rm <service> <security-scan-command>
```

---

## Adopting the Standard

To add LLM-optimized JSON output to an existing Makefile:

1. Read `components[]` from PROJECT.yaml to determine service names
2. Add the AI auto-detection block at the top (CLAUDECODE, CURSOR_SESSION_ID, CODEX_CLI, GEMINI_API_KEY, AI_AGENT)
3. Add `MAKEFLAGS += --no-print-directory` under `ifdef FORMAT`
4. Add `_PASS` and `_SCRIPT_FLAGS` variable blocks (include SUITES in both)
5. Replace the `help` recipe with the `awk`-based self-documenting version
6. Add `## description` annotations to all public targets
7. Add `##   ARG=value` annotations to targets that accept arguments (including SUITES)
8. Wrap test targets with `ifdef FORMAT` / `else` / `endif` branching
9. Create runner scripts for each test framework used in `scripts/` (support `--suites` flag)
10. Add the `test-aggregate.sh` script for aggregator targets
11. Add the `targets` meta-target for target discovery
12. Run `/makefile-optimize` to verify compliance

See: [Makefile Standard Reference](makefile-standard.md)

---

## Migration from manage.sh

If converting from a monolithic bash script to the Makefile pattern:

| manage.sh | Makefile |
|-----------|----------|
| `./manage.sh test <service>` | `make test-<service>` |
| `./manage.sh lint <service> --fix` | `make lint-fix-<service>` |
| `./manage.sh migrate create foo` | `make migrate-new NAME=foo` |
| `./manage.sh logs <service> -f` | `make logs-<service>` |
| Complex status display | `scripts/status.sh` |
| Interactive prompts | `scripts/db-reset.sh` |

---

## Checklist

- [ ] `PROJECT.yaml` defines `components[]` with `path` values for each service
- [ ] Root Makefile with `help` as default target
- [ ] AI auto-detection block in root and all service Makefiles (CLAUDECODE, CURSOR_SESSION_ID, CODEX_CLI, GEMINI_API_KEY, AI_AGENT)
- [ ] `MAKEFLAGS += --no-print-directory` when FORMAT is set (suppresses directory noise globally)
- [ ] Service Makefiles in each component directory (`<path>/Makefile`)
- [ ] Helper scripts in scripts/ for complex operations
- [ ] Target naming: `<action>-<service>-<subtype>` convention (service = component path)
- [ ] `_PASS` variable for forwarding FORMAT/FILES/FILTER/DETAILS/SUITES
- [ ] `_SCRIPT_FLAGS` variable for translating make vars to script flags (includes `--suites`)
- [ ] `ifdef FORMAT` branching: JSON via runner scripts, human via direct tool
- [ ] Runner scripts for each test framework used (only frameworks in use)
- [ ] Runner scripts support `--suites` flag with framework-specific translation
- [ ] `.PHONY` declarations for all non-file targets
- [ ] `@` prefix on commands to hide them from output
- [ ] Self-documenting `##` annotations on all public targets
- [ ] `##   ARG=value` annotations on targets that accept arguments (including SUITES)
- [ ] `awk`-based help recipe (not `grep`) with `[a-zA-Z0-9_-]` character class
- [ ] CI targets defined (`ci-lint`, `ci-test`, `ci-security`)
- [ ] Standard target names used consistently across projects

See also: [Testing Best Practices](testing.md) — JSON contract, database seeding, data isolation
See also: [Makefile Standard Reference](makefile-standard.md) — JSON envelope spec

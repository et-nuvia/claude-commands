# Convert Bash Scripts to Makefile

Migrate project automation from bash scripts to a hierarchical Makefile structure.

---

## Context

This prompt converts projects using bash scripts for automation (like `./scripts/build.sh`, `./scripts/test.sh`) to using Makefiles. Makefiles provide:
- Tab-completion for targets
- Dependency management between tasks
- Self-documenting help output
- Standardized interface across projects

---

## Prerequisites

- Project currently uses bash scripts in `./scripts/` or similar
- Docker Compose setup exists
- Basic understanding of what each script does

---

## Prompt

```
I want to convert this project from using bash scripts for automation to using Makefiles.

## Current State Analysis

First, analyze the existing automation:

1. Find all bash scripts used for project automation:
   - Check `./scripts/`, `./bin/`, root directory for `.sh` files
   - Check package.json scripts section (if Node.js)
   - Check any existing Makefile

2. For each script, identify:
   - What it does (build, test, deploy, etc.)
   - What dependencies it has (other scripts, services)
   - What arguments/environment variables it accepts
   - Whether it runs inside Docker or on the host

3. Identify the project structure:
   - Is this a monorepo with multiple services?
   - What are the main components (backend, frontend, etc.)?

## Target Structure

Create this Makefile structure based on my global guidelines:

```
project/
├── Makefile              # Root orchestrator
├── scripts/              # Complex bash operations only
│   ├── wait-for-it.sh
│   └── [other complex scripts]
├── backend/
│   └── Makefile          # Backend-specific targets
└── frontend/
    └── Makefile          # Frontend-specific targets
```

## Makefile Requirements

1. **Root Makefile must include:**
   - `.PHONY` declarations for all targets
   - `.DEFAULT_GOAL := help`
   - Color-coded help target using awk
   - Section headers with `##@`
   - All targets documented with `## Description`

2. **Standard targets to implement:**
   - `up` - Start all services
   - `down` - Stop all services
   - `build` - Build all containers
   - `test` - Run all tests
   - `lint` - Run linters
   - `format` - Format code
   - `typecheck` - Run type checking
   - `clean` - Remove build artifacts
   - `logs` - Tail logs
   - `shell` - Open shell in container

3. **CI-specific targets:**
   - `ci-lint` - Lint with CI-appropriate output
   - `ci-test` - Test with coverage
   - `ci-typecheck` - Type check with JSON output

4. **For monorepos, delegate to component Makefiles:**
   ```makefile
   test:
   	$(MAKE) -C backend test
   	$(MAKE) -C frontend test
   ```

5. **All commands must run inside Docker containers:**
   ```makefile
   lint:
   	docker compose run --rm app ruff check .
   ```

## Migration Steps

1. Create the root Makefile with help system
2. Migrate each bash script to a Make target
3. Create component Makefiles if monorepo
4. Move only complex scripts (multi-step, interactive) to scripts/
5. Update any CI/CD pipelines to use `make` commands
6. Update README with new commands
7. Test all targets work correctly

## Validation

After migration:
- `make help` shows all available commands
- `make up` starts the project
- `make test` runs all tests
- `make lint` runs linters
- CI pipeline passes with new make commands

## Keep in scripts/

Only keep bash scripts for:
- Complex multi-step operations with conditionals
- Interactive prompts
- Service health checks (wait-for-it)
- Operations that need to be sourced

Everything else should be a Make target.

Now analyze this project and create the Makefile structure.
```

---

## Example Output

The migration should produce something like:

**Root Makefile:**
```makefile
.PHONY: help up down build test lint format typecheck clean logs shell

.DEFAULT_GOAL := help

# Colors
BLUE := \033[34m
GREEN := \033[32m
YELLOW := \033[33m
RESET := \033[0m

##@ General

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\n$(BLUE)Usage:$(RESET)\n  make $(GREEN)<target>$(RESET)\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-15s$(RESET) %s\n", $$1, $$2 } \
		/^##@/ { printf "\n$(YELLOW)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Development

up: ## Start all services
	docker compose up -d

down: ## Stop all services
	docker compose down

build: ## Build all containers
	docker compose build

logs: ## Tail all logs
	docker compose logs -f

shell: ## Open shell in app container
	docker compose exec app /bin/sh

##@ Code Quality

lint: ## Run linters
	docker compose run --rm app ruff check .

format: ## Format code
	docker compose run --rm app ruff format .

typecheck: ## Run type checking
	docker compose run --rm app pyright

##@ Testing

test: ## Run all tests
	docker compose run --rm app pytest tests/ -v

##@ CI

ci-lint: ## CI: Run linters
	docker compose run --rm app ruff check . --output-format=github

ci-test: ## CI: Run tests with coverage
	docker compose build --build-arg RUN_TESTS=true app

##@ Cleanup

clean: ## Remove containers and build artifacts
	docker compose down -v --remove-orphans
```

---

## Rollback

If the migration causes issues:

1. Git revert the Makefile changes
2. Restore original scripts from git history
3. Update CI/CD back to script commands

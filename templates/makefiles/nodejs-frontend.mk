# Frontend Makefile (Next.js/React)
.PHONY: help up down test lint format typecheck build clean targets ci-lint ci-test ci-typecheck

# LLM-optimized output support
FORMAT ?= human
MAKEFLAGS += --no-print-directory
JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh
COMPONENT ?= frontend

# Default target
.DEFAULT_GOAL := help

help:
	@echo "Frontend (Node.js) targets:"
	@echo "  up         - Start frontend service"
	@echo "  down       - Stop frontend service"
	@echo "  test       - Run tests"
	@echo "  lint       - Run linter (ESLint)"
	@echo "  format     - Format code (Prettier)"
	@echo "  typecheck  - Run type checker (tsc)"
	@echo "  build      - Build for production"
	@echo "  clean      - Clean build artifacts"
	@echo "  targets    - List targets (FORMAT=json for structured output)"

up:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target up --component $(COMPONENT) --category service \
		-- docker compose up -d frontend
else
	docker compose up -d frontend
	@echo "✓ Frontend running on http://localhost:${FRONTEND_PORT}"
endif

down:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target down --component $(COMPONENT) --category service \
		-- docker compose down
else
	docker compose down
endif

test:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target test --component $(COMPONENT) --category testing \
		-- docker compose run --rm frontend npm test $(ARGS)
else
	docker compose run --rm frontend npm test $(ARGS)
endif

lint:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target lint --component $(COMPONENT) --category quality \
		-- docker compose run --rm frontend npm run lint
else
	docker compose run --rm frontend npm run lint
endif

format:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target format --component $(COMPONENT) --category quality \
		-- docker compose run --rm frontend npm run format
else
	docker compose run --rm frontend npm run format
endif

typecheck:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target typecheck --component $(COMPONENT) --category quality \
		-- docker compose run --rm frontend npm run typecheck
else
	docker compose run --rm frontend npm run typecheck
endif

build:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target build --component $(COMPONENT) \
		-- docker compose run --rm frontend npm run build
else
	docker compose run --rm frontend npm run build
endif

clean:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target clean --component $(COMPONENT) \
		-- sh -c 'rm -rf node_modules/ .next/ dist/ build/ coverage/ 2>/dev/null; echo "Clean complete"'
else
	@echo "Cleaning Node.js build artifacts..."
	@rm -rf node_modules/ 2>/dev/null || true
	@rm -rf .next/ 2>/dev/null || true
	@rm -rf dist/ 2>/dev/null || true
	@rm -rf build/ 2>/dev/null || true
	@rm -rf coverage/ 2>/dev/null || true
	@echo "✓ Clean complete"
endif

targets:
ifeq ($(FORMAT),json)
	@echo '{"status":"success","target":"targets","component":"$(COMPONENT)","targets":[{"name":"up","description":"Start frontend service","format_support":true},{"name":"down","description":"Stop frontend service","format_support":true},{"name":"test","description":"Run tests","format_support":true},{"name":"lint","description":"Run linter (ESLint)","format_support":true},{"name":"format","description":"Format code (Prettier)","format_support":true},{"name":"typecheck","description":"Run type checker (tsc)","format_support":true},{"name":"build","description":"Build for production","format_support":true},{"name":"clean","description":"Clean build artifacts","format_support":true}]}'
else
	@$(MAKE) help
endif

# CI targets (no color output, exit on error)
ci-lint:
	npm run lint -- --no-color

ci-test:
	npm test -- --no-color --passWithNoTests --coverage

ci-typecheck:
	npm run typecheck

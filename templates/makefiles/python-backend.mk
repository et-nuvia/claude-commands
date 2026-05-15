# Backend Makefile (Python/FastAPI)
.PHONY: help up down test lint format typecheck migrate clean targets ci-lint ci-test ci-typecheck

# LLM-optimized output support
FORMAT ?= human
MAKEFLAGS += --no-print-directory
JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh
COMPONENT ?= backend

# Default target
.DEFAULT_GOAL := help

help:
	@echo "Backend (Python) targets:"
	@echo "  up         - Start backend service"
	@echo "  down       - Stop backend service"
	@echo "  test       - Run tests with coverage"
	@echo "  lint       - Run linter (ruff)"
	@echo "  format     - Format code (ruff)"
	@echo "  typecheck  - Run type checker (pyright)"
	@echo "  migrate    - Run database migrations"
	@echo "  clean      - Clean build artifacts"
	@echo "  targets    - List targets (FORMAT=json for structured output)"

up:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target up --component $(COMPONENT) --category service \
		-- docker compose up -d ${APP_SERVICE}
else
	docker compose up -d ${APP_SERVICE}
	@echo "✓ Backend running on http://localhost:${APP_PORT}"
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
		-- docker compose run --rm ${APP_SERVICE} pytest ${TEST_DIR}/ -v --cov=${SOURCE_DIR} $(ARGS)
else
	docker compose run --rm ${APP_SERVICE} pytest ${TEST_DIR}/ -v --cov=${SOURCE_DIR} --cov-report=term-missing $(ARGS)
endif

lint:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target lint --component $(COMPONENT) --category quality \
		-- docker compose run --rm ${APP_SERVICE} ruff check ${SOURCE_DIR}/
else
	docker compose run --rm ${APP_SERVICE} ruff check ${SOURCE_DIR}/
endif

format:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target format --component $(COMPONENT) --category quality \
		-- docker compose run --rm ${APP_SERVICE} ruff format ${SOURCE_DIR}/
else
	docker compose run --rm ${APP_SERVICE} ruff format ${SOURCE_DIR}/
endif

typecheck:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target typecheck --component $(COMPONENT) --category quality \
		-- docker compose run --rm ${APP_SERVICE} pyright ${SOURCE_DIR}/
else
	docker compose run --rm ${APP_SERVICE} pyright ${SOURCE_DIR}/
endif

migrate:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target migrate --component $(COMPONENT) \
		-- docker compose run --rm ${APP_SERVICE} alembic upgrade head
else
	docker compose run --rm ${APP_SERVICE} alembic upgrade head
endif

clean:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target clean --component $(COMPONENT) \
		-- sh -c 'find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null; find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null; find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null; find . -type d -name ".ruff_cache" -exec rm -rf {} + 2>/dev/null; find . -type f -name "*.pyc" -delete 2>/dev/null; rm -rf .coverage htmlcov/ 2>/dev/null; echo "Clean complete"'
else
	@echo "Cleaning Python build artifacts..."
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name ".ruff_cache" -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@rm -rf .coverage htmlcov/ 2>/dev/null || true
	@echo "✓ Clean complete"
endif

targets:
ifeq ($(FORMAT),json)
	@echo '{"status":"success","target":"targets","component":"$(COMPONENT)","targets":[{"name":"up","description":"Start backend service","format_support":true},{"name":"down","description":"Stop backend service","format_support":true},{"name":"test","description":"Run tests with coverage","format_support":true},{"name":"lint","description":"Run linter (ruff)","format_support":true},{"name":"format","description":"Format code (ruff)","format_support":true},{"name":"typecheck","description":"Run type checker (pyright)","format_support":true},{"name":"migrate","description":"Run database migrations","format_support":true},{"name":"clean","description":"Clean build artifacts","format_support":true}]}'
else
	@$(MAKE) help
endif

# CI targets (no color output, exit on error)
ci-lint:
	ruff check ${SOURCE_DIR}/ --no-color

ci-test:
	pytest ${TEST_DIR}/ -v --no-color --tb=short --cov=${SOURCE_DIR} --cov-report=term-missing --cov-fail-under=${MIN_COVERAGE}

ci-typecheck:
	pyright ${SOURCE_DIR}/ --outputjson

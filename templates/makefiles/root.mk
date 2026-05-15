# Root Makefile - Orchestrates component Makefiles
.PHONY: help up down test lint format typecheck migrate build clean status targets

# LLM-optimized output support
FORMAT ?= human
MAKEFLAGS += --no-print-directory
JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh
COMPONENT ?= root

# Default target
.DEFAULT_GOAL := help

help:
	@echo "═══════════════════════════════════════"
	@echo "Available targets:"
	@echo "═══════════════════════════════════════"
	@echo "  help       - Show this help message"
	@echo "  up         - Start all services"
	@echo "  down       - Stop all services"
	@echo "  test       - Run all tests"
	@echo "  lint       - Run all linters"
	@echo "  format     - Format all code"
	@echo "  typecheck  - Run type checking"
	@echo "  migrate    - Run database migrations"
	@echo "  build      - Build all components"
	@echo "  clean      - Clean build artifacts"
	@echo "  status     - Show service status"
	@echo "  targets    - List targets (FORMAT=json for structured output)"

#IF:HAS_BACKEND
.PHONY: up-backend down-backend test-backend lint-backend format-backend typecheck-backend migrate-backend

up-backend:
	@echo "Starting backend..."
	$(MAKE) -C ${BACKEND_DIR} up FORMAT=$(FORMAT)

down-backend:
	@echo "Stopping backend..."
	$(MAKE) -C ${BACKEND_DIR} down FORMAT=$(FORMAT)

test-backend:
	@echo "Testing backend..."
	$(MAKE) -C ${BACKEND_DIR} test FORMAT=$(FORMAT) ARGS="$(ARGS)"

lint-backend:
	@echo "Linting backend..."
	$(MAKE) -C ${BACKEND_DIR} lint FORMAT=$(FORMAT)

format-backend:
	@echo "Formatting backend..."
	$(MAKE) -C ${BACKEND_DIR} format FORMAT=$(FORMAT)

typecheck-backend:
	@echo "Type checking backend..."
	$(MAKE) -C ${BACKEND_DIR} typecheck FORMAT=$(FORMAT)

migrate-backend:
	@echo "Running backend migrations..."
	$(MAKE) -C ${BACKEND_DIR} migrate FORMAT=$(FORMAT)
#ENDIF:HAS_BACKEND

#IF:HAS_FRONTEND
.PHONY: up-frontend down-frontend test-frontend lint-frontend format-frontend typecheck-frontend build-frontend

up-frontend:
	@echo "Starting frontend..."
	$(MAKE) -C ${FRONTEND_DIR} up FORMAT=$(FORMAT)

down-frontend:
	@echo "Stopping frontend..."
	$(MAKE) -C ${FRONTEND_DIR} down FORMAT=$(FORMAT)

test-frontend:
	@echo "Testing frontend..."
	$(MAKE) -C ${FRONTEND_DIR} test FORMAT=$(FORMAT) ARGS="$(ARGS)"

lint-frontend:
	@echo "Linting frontend..."
	$(MAKE) -C ${FRONTEND_DIR} lint FORMAT=$(FORMAT)

format-frontend:
	@echo "Formatting frontend..."
	$(MAKE) -C ${FRONTEND_DIR} format FORMAT=$(FORMAT)

typecheck-frontend:
	@echo "Type checking frontend..."
	$(MAKE) -C ${FRONTEND_DIR} typecheck FORMAT=$(FORMAT)

build-frontend:
	@echo "Building frontend..."
	$(MAKE) -C ${FRONTEND_DIR} build FORMAT=$(FORMAT)
#ENDIF:HAS_FRONTEND

# Combined targets
up:
#IF:HAS_BACKEND
	@$(MAKE) up-backend
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) up-frontend
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ All services started"
endif

down:
#IF:HAS_BACKEND
	@$(MAKE) down-backend
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) down-frontend
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ All services stopped"
endif

test:
#IF:HAS_BACKEND
	@$(MAKE) test-backend
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) test-frontend
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ All tests passed"
endif

lint:
#IF:HAS_BACKEND
	@$(MAKE) lint-backend
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) lint-frontend
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ All linters passed"
endif

format:
#IF:HAS_BACKEND
	@$(MAKE) format-backend
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) format-frontend
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ All code formatted"
endif

typecheck:
#IF:HAS_BACKEND
	@$(MAKE) typecheck-backend
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) typecheck-frontend
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ All type checks passed"
endif

#IF:HAS_DATABASE
migrate:
#IF:HAS_BACKEND
	@$(MAKE) migrate-backend
#ENDIF:HAS_BACKEND
ifeq ($(FORMAT),human)
	@echo "✓ Migrations complete"
endif
#ENDIF:HAS_DATABASE

#IF:HAS_FRONTEND
build:
	@$(MAKE) build-frontend
ifeq ($(FORMAT),human)
	@echo "✓ Build complete"
endif
#ENDIF:HAS_FRONTEND

status:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target status --component $(COMPONENT) --category service \
		-- docker compose ps
else
	@echo "Service Status:"
	@docker compose ps 2>/dev/null || echo "No docker compose services found"
endif

clean:
ifeq ($(FORMAT),human)
	@echo "Cleaning build artifacts..."
endif
#IF:HAS_BACKEND
	@$(MAKE) -C ${BACKEND_DIR} clean FORMAT=$(FORMAT) 2>/dev/null || true
#ENDIF:HAS_BACKEND
#IF:HAS_FRONTEND
	@$(MAKE) -C ${FRONTEND_DIR} clean FORMAT=$(FORMAT) 2>/dev/null || true
#ENDIF:HAS_FRONTEND
ifeq ($(FORMAT),human)
	@echo "✓ Clean complete"
endif

targets:
ifeq ($(FORMAT),json)
	@echo '{"status":"success","target":"targets","component":"$(COMPONENT)","targets":[{"name":"up","description":"Start all services","format_support":true},{"name":"down","description":"Stop all services","format_support":true},{"name":"test","description":"Run all tests","format_support":true},{"name":"lint","description":"Run all linters","format_support":true},{"name":"format","description":"Format all code","format_support":true},{"name":"typecheck","description":"Run type checking","format_support":true},{"name":"status","description":"Show service status","format_support":true},{"name":"clean","description":"Clean build artifacts","format_support":true}]}'
else
	@$(MAKE) help
endif

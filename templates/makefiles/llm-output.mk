# llm-output.mk - LLM-optimized output support for Makefiles
#
# Include this file in component and root Makefiles to enable FORMAT=json output.
#
# Usage in Makefile:
#   include llm-output.mk
#
#   test:
#   ifeq ($(FORMAT),json)
#   	@$(JSON_WRAPPER) --target test --component $(COMPONENT) --category testing \
#   		-- docker compose run --rm $(APP_SERVICE) pytest $(TEST_DIR)/ -v
#   else
#   	docker compose run --rm $(APP_SERVICE) pytest $(TEST_DIR)/ -v --cov-report=term-missing
#   endif
#
# Variables:
#   FORMAT        - Output format: human (default) or json
#   JSON_WRAPPER  - Path to make-json-wrapper.sh (auto-set)
#   COMPONENT     - Component name, set per-Makefile (e.g., backend, frontend)

FORMAT ?= human
MAKEFLAGS += --no-print-directory
JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh

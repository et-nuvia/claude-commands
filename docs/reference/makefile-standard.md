# Makefile Standard Reference

Normative reference for standardized Makefile targets, JSON output format, and adoption rules.

---

## Standard Targets

Every project must implement applicable targets from this table:

| Target | Category | Required | JSON fields |
|--------|----------|----------|-------------|
| `up` | service | yes | `services: [{name, port, url}]` |
| `down` | service | yes | `services_stopped: int` |
| `status` | service | yes | `services: [{name, state, port}]` |
| `test` | testing | yes | `passed, failed, skipped, coverage_pct, duration_ms` |
| `test-e2e` | testing | no | `passed, failed, skipped, duration_ms` |
| `test-api` | testing | no | `passed, failed, skipped, duration_ms` |
| `coverage-report` | testing | no | `snapshots, current, trend` |
| `lint` | quality | yes | `errors, warnings, files_checked` |
| `format` | quality | yes | `files_changed` |
| `typecheck` | quality | yes | `errors, warnings` |
| `migrate` | database | no | `migrations_applied, current_head` |
| `build` | build | no | `image_tag, duration_ms` |
| `clean` | lifecycle | yes | `items_removed` |
| `targets` | meta | yes | `targets: [{name, description, format_support}]` |

---

## JSON Envelope

All targets producing JSON output use this standard envelope:

```json
{
  "status": "success|error",
  "target": "test",
  "component": "backend",
  "message": "12 passed, 0 failed",
  "next_action": "display_summary|fix_error",
  "exit_code": 0,
  "duration_ms": 1234,
  "timestamp": "2026-03-01T12:00:00-05:00"
}
```

**Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `status` | string | yes | `success` or `error` |
| `target` | string | yes | Make target name |
| `component` | string | yes | Component name (backend, frontend, root) |
| `message` | string | yes | Human-readable summary |
| `next_action` | string | yes | LLM directive: `display_summary`, `fix_error`, `fix_failures` |
| `exit_code` | int | yes | Command exit code |
| `duration_ms` | int | yes | Execution time in milliseconds |
| `timestamp` | string | yes | ISO 8601 timestamp |

Target-specific fields are merged into the envelope (see Standard Targets table).

---

## Adoption Rules

### Required in Every Makefile

1. `FORMAT ?= human` at the top
2. `MAKEFLAGS += --no-print-directory`
3. Include `llm-output.mk` or set `JSON_WRAPPER` manually
4. All targets must support `FORMAT=json`
5. Use `@` prefix on all recipe lines
6. Implement the `targets` meta-target

### Component Makefiles

```makefile
include llm-output.mk
COMPONENT ?= backend

test:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target test --component $(COMPONENT) --category testing \
		-- docker compose run --rm $(APP_SERVICE) pytest $(TEST_DIR)/ -v --cov=$(SOURCE_DIR)
else
	docker compose run --rm $(APP_SERVICE) pytest $(TEST_DIR)/ -v --cov=$(SOURCE_DIR) --cov-report=term-missing
endif
```

### Root Makefiles

Root Makefiles aggregate component results:

```makefile
test:
ifeq ($(FORMAT),json)
	@results="[]"; exit_code=0; \
	for comp in $(COMPONENTS); do \
		r=$$($(MAKE) -C $$comp test FORMAT=json 2>/dev/null) || exit_code=$$?; \
		results=$$(echo "$$results" | python3 -c "import sys,json; l=json.load(sys.stdin); l.append(json.loads('$$r')); print(json.dumps(l))"); \
	done; \
	echo "{\"status\":$$([ $$exit_code -eq 0 ] && echo '\"success\"' || echo '\"error\"'),\"target\":\"test\",\"component\":\"root\",\"components\":$$results}"
else
	$(MAKE) -C backend test
	$(MAKE) -C frontend test
endif
```

### ARGS Passthrough

Targets accept additional arguments via `ARGS`:

```makefile
# Usage: make test FORMAT=json ARGS="--file tests/test_auth.py -k test_login"
test:
ifeq ($(FORMAT),json)
	@$(JSON_WRAPPER) --target test --component $(COMPONENT) --category testing \
		-- docker compose run --rm $(APP_SERVICE) pytest $(TEST_DIR)/ $(ARGS)
else
	docker compose run --rm $(APP_SERVICE) pytest $(TEST_DIR)/ -v $(ARGS)
endif
```

---

## Target Discovery

Every Makefile must implement `targets` for runtime discovery:

```makefile
targets:
ifeq ($(FORMAT),json)
	@echo '{"status":"success","target":"targets","component":"$(COMPONENT)","targets":[{"name":"test","description":"Run tests","format_support":true},{"name":"lint","description":"Run linter","format_support":true}]}'
else
	@$(MAKE) help
endif
```

Scripts check for FORMAT=json support:

```bash
# Check if Makefile supports FORMAT=json
make -n test FORMAT=json >/dev/null 2>&1
```

---

## next_action Values

| Value | Meaning | When |
|-------|---------|------|
| `display_summary` | Show results, no action needed | All tests pass, lint clean |
| `fix_error` | Infrastructure/config error | Command failed to run |
| `fix_failures` | Test failures need code fixes | Tests ran but some failed |
| `confirm_action` | User confirmation needed | Destructive operation |

---

## Category-Specific Parsing

The `make-json-wrapper.sh` uses `--category` to determine parsing:

| Category | Parser | Extracted Fields |
|----------|--------|------------------|
| `testing` | `parse-test-output.sh` | passed, failed, skipped, coverage_pct, duration_ms |
| `quality` | Built-in | errors, warnings, files_checked |
| `service` | Built-in | services array with name/state/port |
| `default` | None | Raw output in message field |

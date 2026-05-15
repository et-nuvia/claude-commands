# Migration Checklist Template

**Usage**: Copy this checklist for each command/script pair being migrated.
Replace `[COMMAND]` with the actual command name.

---

## Command: [COMMAND]

**Migrated by**: [agent/date]
**Priority**: P0/P1/P2/P3

### Before Migration (Baseline)

| Metric | Value |
|--------|-------|
| Command lines | |
| Bash blocks | |
| jq calls | |
| case statements | |
| Decision trees | |

### Command File (`commands/[COMMAND].md`)

- [ ] Total lines ≤ 150
- [ ] Bash blocks ≤ 3
- [ ] No jq parsing code
- [ ] No case statements on data fields (only on status/next_action)
- [ ] No decision tree logic
- [ ] No field extraction patterns
- [ ] Documents workflow steps only
- [ ] Documents next_action values and what LLM does for each
- [ ] Includes 1-2 usage examples
- [ ] Explains -v/-vv debugging option

### Script File (`scripts/[COMMAND].sh`)

- [ ] Auto-reads PROJECT.yaml using `lib/project-config.sh`
- [ ] Single `get_project_config()` call (batched, no sequential calls)
- [ ] Returns `next_action` field in all responses
- [ ] Supports `-v` flag (verbosity level 1 - context)
- [ ] Supports `-vv` flag (verbosity level 2 - debug)
- [ ] All config via flags (no env var dependencies)
- [ ] Returns minimal data at level 0
- [ ] Handles all decision logic internally (not in command)
- [ ] Uses `run_quiet()` for all subprocess calls
- [ ] No output bleed (only final JSON to stdout)
- [ ] Handles `__MISSING__`/`__BLANK__`/`__INVALID__` config gracefully
- [ ] Exit code 0 on success, non-zero on error
- [ ] `set -euo pipefail` at top

### Testing (`scripts/tests/test-[COMMAND].bats`)

- [ ] Test file created
- [ ] Success path tested
- [ ] Error paths tested (bad input, missing config, API failure)
- [ ] Verbosity level 0 tested (minimal JSON, no bleed)
- [ ] Verbosity level 1 tested (context fields present)
- [ ] Verbosity level 2 tested (debug fields present)
- [ ] `__MISSING__` PROJECT.yaml config tested
- [ ] `__BLANK__` PROJECT.yaml config tested
- [ ] `__INVALID__` PROJECT.yaml path tested
- [ ] All tests pass

### After Migration (Results)

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Command lines | | | % |
| Bash blocks | | | % |
| jq calls | | | % |
| case statements | | | % |

### Notes

_Any special patterns, exceptions, or issues discovered during migration._

---

## Quick Validation Commands

```bash
# Count command lines
wc -l commands/[COMMAND].md

# Count bash blocks
grep -c '```bash' commands/[COMMAND].md

# Check for jq in command (should be 0 outside the execute block)
grep -c 'jq ' commands/[COMMAND].md

# Verify script returns next_action
~/.claude/scripts/[COMMAND].sh --help 2>&1 | head -5
~/.claude/scripts/[COMMAND].sh [test-args] | jq '.next_action'

# Run tests
bats scripts/tests/test-[COMMAND].bats
```

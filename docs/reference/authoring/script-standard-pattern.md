# Standard Script Pattern

**Version**: 1.0
**Date**: 2026-02-14
**Status**: Standard for all scripts

---

## Overview

All scripts in `~/.claude/scripts/` MUST follow this standard pattern. This pattern enables:
- **Auto-flow**: Scripts run end-to-end when successful (no user intervention)
- **LLM intervention**: Smart pauses only when needed (conflicts, errors, decisions)
- **Debuggability**: Structured JSON output plus verbose --raw mode
- **Composability**: Section flags allow resuming after fixes

---

## Standard Flags

Every script MUST support these flags:

### Output Modes
```bash
--json    # Structured JSON output (default, for LLM parsing)
--raw     # Verbose debugging output (when --json insufficient)
```

### Section Flags
```bash
--full           # Run all sections end-to-end (default)
--section-name   # Run specific section only
```

**Example section flags:**
- `--validate`: Check prerequisites
- `--merge`: Attempt merge (may return conflicts)
- `--deploy`: Execute deployment
- `--cleanup`: Cleanup after completion

---

## Script Template

```bash
#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/my-script.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Validate prerequisites
#   --execute:   Execute main operation
#   --cleanup:   Cleanup after execution
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If error: Returns JSON with error details
#   3. LLM can retry with --raw for more debugging info
#   4. Or LLM runs specific --section after fixing issue

# Colors for output (only in raw mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, execute, cleanup

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log() {
    # Only output in raw mode (stderr so doesn't pollute JSON)
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

log_json() {
    # Always output JSON to stdout for LLM
    echo "$1"
}

exit_with_json() {
    local status="$1"
    local message="$2"
    local details="${3:-}"

    local json=$(cat <<EOF
{
  "status": "$status",
  "message": "$message",
  "section": "$SECTION",
  "details": $(echo "$details" | jq -Rs . 2>/dev/null || echo '""'),
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    exit $(if [[ "$status" == "success" ]]; then echo 0; else echo 1; fi)
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate
section_validate() {
    log "${BLUE}Validating Prerequisites${NC}"

    # Do validation work here
    # ...

    # If running only this section, return now
    if [[ "$SECTION" == "validate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "validate",
  "message": "Validation complete",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Execute (LLM intervention point)
section_execute() {
    log "${BLUE}Executing Main Operation${NC}"

    # Attempt operation
    local result
    if ! result=$(some_operation 2>&1); then
        # Operation failed - return error details for LLM
        if [[ "$SECTION" == "execute" ]]; then
            local json=$(cat <<EOF
{
  "status": "error",
  "section": "execute",
  "message": "Operation failed - LLM intervention required",
  "error_details": $(echo "$result" | jq -Rs .),
  "next_steps": [
    "LLM should analyze error details",
    "Fix the issue using appropriate tools",
    "Then continue: script.sh --json --cleanup"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 1
        else
            # In --full mode, exit with error
            exit_with_json "error" "Operation failed" "$result"
        fi
    fi

    # Success
    if [[ "$SECTION" == "execute" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "execute",
  "message": "Operation completed successfully",
  "result": $(echo "$result" | jq -Rs .),
  "next_steps": [
    "Continue cleanup: script.sh --json --cleanup"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Operation complete"
}

# Section 3: Cleanup
section_cleanup() {
    log "${BLUE}Cleaning Up${NC}"

    # Cleanup work here
    # ...

    if [[ "$SECTION" == "cleanup" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "cleanup",
  "message": "Cleanup complete",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Cleanup complete"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --validate) SECTION="validate"; shift ;;
            --execute) SECTION="execute"; shift ;;
            --cleanup) SECTION="cleanup"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        execute)
            section_validate  # Prerequisites first
            section_execute
            ;;
        cleanup)
            # Assume execute already done
            section_cleanup
            ;;
        full)
            section_validate
            section_execute
            section_cleanup

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "message": "All sections completed successfully",
  "sections_completed": ["validate", "execute", "cleanup"],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
```

---

## Design Principles

### 1. Auto-Flow by Default

**Good:** Everything succeeds → runs end-to-end, no intervention
```bash
script.sh --json --full
# → {"status":"success", ...}
```

**Bad:** Prompting for every step even when successful
```bash
# Don't do this:
echo "Continue? (y/n)"
read -p "> " CONFIRM
```

### 2. Strategic LLM Intervention Points (1-2 max)

**Good:** Pause only where human/LLM decision needed
- Merge conflicts (can't auto-resolve)
- Risk score borderline (needs judgment)
- External service down (may need manual fix)

**Bad:** Pausing for routine operations
- File exists check
- Simple validation
- Non-critical warnings

### 3. Structured JSON Output

**Good:** Parseable, actionable JSON
```json
{
  "status": "conflict",
  "section": "merge",
  "conflict_files": ["auth.py", "db.py"],
  "conflict_details": "<<<<<<< HEAD\n...",
  "next_steps": ["Resolve conflicts", "Run: script.sh --json --deploy"]
}
```

**Bad:** Plain text that LLM must parse
```
Error: merge conflicts
Files: auth.py db.py
```

### 4. --raw Mode for Debugging

When JSON insufficient, LLM can request verbose output:
```bash
# First try: JSON (concise)
script.sh --json --merge
# → {"status":"error", "message":"Merge failed"}

# Second try: Raw (verbose)
script.sh --raw --merge
# → Full git diff output, detailed logs, etc.
```

---

## Section Design Guidelines

### How Many Sections?

**Good:** 3-5 logical sections
- Too few (1-2): Not enough control
- Too many (6+): Overly complex

**Example (deploy script):**
1. `--validate`: Check prerequisites
2. `--merge`: Attempt merge (intervention point)
3. `--deploy`: Pipeline + health + tests
4. `--tag`: Create release tag (optional)

### Section Independence

Each section should:
- ✅ Be runnable independently (with prerequisites)
- ✅ Have clear input/output contract
- ✅ Return JSON with status and next steps
- ❌ Depend on internal state from other sections (use flags/args instead)

**Good:**
```bash
script.sh --json --deploy  # Can run alone (assumes merge done)
```

**Bad:**
```bash
# Requires complex state from previous sections
# Better to use --full or pass state via flags
```

### Naming Conventions

Section flags should be:
- Imperative verbs: `--validate`, `--merge`, `--deploy`
- Clear and concise: `--cleanup` not `--do-cleanup-operations`
- Ordered logically: Match execution order

---

## Error Handling

### Success Response

```json
{
  "status": "success",
  "section": "deploy",
  "message": "Deployment completed successfully",
  "details": {...},
  "timestamp": "2026-02-14T10:30:00-05:00"
}
```

### Error Response (Blocking)

```json
{
  "status": "error",
  "section": "validate",
  "message": "PROJECT.yaml not found",
  "details": "Run: /project-config init",
  "timestamp": "2026-02-14T10:30:00-05:00"
}
```

### Conflict Response (LLM Intervention)

```json
{
  "status": "conflict",
  "section": "merge",
  "message": "Merge conflicts detected - LLM intervention required",
  "conflict_files": ["src/auth.py", "src/db.py"],
  "conflict_count": 2,
  "conflict_details": "File: src/auth.py\n<<<<<<< HEAD\n...",
  "next_steps": [
    "LLM should resolve conflicts in listed files",
    "After resolving: git add <files>",
    "Then continue: script.sh --json --deploy"
  ],
  "timestamp": "2026-02-14T10:30:00-05:00"
}
```

### Warning Response (Non-Blocking)

```json
{
  "status": "success",
  "section": "deploy",
  "message": "Deployment succeeded with warnings",
  "warnings": [
    "Health check failed (non-blocking)",
    "Version verification skipped"
  ],
  "timestamp": "2026-02-14T10:30:00-05:00"
}
```

---

## Real-World Examples

### Example 1: deploy-to-stage.sh

**Sections:**
- `--validate`: Check git state, load config
- `--risk-analysis`: Run automated risk check
- `--merge`: Attempt squash merge (intervention point if conflicts)
- `--deploy`: Pipeline + health + version + e2e tests

**Workflow:**
```bash
# Happy path (no conflicts)
deploy-to-stage.sh --json --full
# → Returns: {"status":"success", "deployment":"staging", ...}

# Conflict path
deploy-to-stage.sh --json --full
# → Returns: {"status":"conflict", "conflict_files":["auth.py"], ...}
# LLM resolves conflicts
deploy-to-stage.sh --json --deploy
# → Returns: {"status":"success", "pipeline_status":"passed", ...}
```

### Example 2: create-pr.sh

**Sections:**
- `--analyze`: Analyze commits and changes
- `--push`: Push branch to remote
- `--full`: Analyze + push + return JSON for description

**Workflow:**
```bash
# Script handles mechanics, LLM handles description
create-pr.sh --json --full
# → Returns: {"status":"ready_for_description", "commits":[...], "files":[...]}
# LLM generates description from commit data
# LLM creates PR: gh pr create --title "..." --body "..."
```

---

## Migration Guide

### Converting Existing Scripts

1. **Identify logical sections** (3-5)
   - Where might LLM need to intervene?
   - What are the natural breakpoints?

2. **Add standard flags**
   ```bash
   OUTPUT_MODE="json"
   SECTION="full"
   ```

3. **Wrap each section**
   ```bash
   section_name() {
       # Do work
       if [[ "$SECTION" == "name" ]]; then
           exit_with_json "success" "Section complete"
       fi
   }
   ```

4. **Update main()**
   ```bash
   main() {
       # Parse flags
       while [[ $# -gt 0 ]]; do
           case $1 in
               --json) OUTPUT_MODE="json"; shift ;;
               --raw) OUTPUT_MODE="raw"; shift ;;
               --section-name) SECTION="section-name"; shift ;;
               --full) SECTION="full"; shift ;;
               *) shift ;;
           esac
       done

       # Execute sections
       case "$SECTION" in
           section-name) section_name ;;
           full) section_one; section_two; exit_with_json "success" "Complete" ;;
       esac
   }
   ```

5. **Test all paths**
   ```bash
   # Test full execution
   script.sh --json --full

   # Test each section
   script.sh --json --section1
   script.sh --json --section2

   # Test raw mode
   script.sh --raw --full
   ```

---

## Checklist

Before committing a new script, verify:

- [ ] Script follows standard template structure
- [ ] Supports `--json` and `--raw` output modes
- [ ] Supports `--full` and section flags
- [ ] Has 3-5 logical sections
- [ ] Each section returns JSON when run independently
- [ ] LLM intervention points are strategic (1-2 max)
- [ ] Error messages include `next_steps` array
- [ ] Auto-flows when successful (no unnecessary prompts)
- [ ] Bash syntax validated: `bash -n script.sh`
- [ ] Executable: `chmod +x script.sh`
- [ ] Header comment explains usage and sections
- [ ] All sections documented in header

---

## Anti-Patterns

### ❌ Don't: Prompt for routine operations
```bash
read -p "Run validation? (y/n): " RUN_VALIDATION
```

### ✅ Do: Auto-flow with section flags
```bash
# Validation runs automatically in --full mode
# Can skip with --deploy if already validated
```

### ❌ Don't: Output mixed text and JSON
```bash
echo "Starting deployment..."  # This breaks JSON parsing
echo '{"status":"success"}'
```

### ✅ Do: Separate concerns (stderr vs stdout)
```bash
log "Starting deployment..."  # Goes to stderr (only in --raw)
log_json '{"status":"success"}'  # Goes to stdout
```

### ❌ Don't: Create too many sections
```bash
--check-1, --check-2, --check-3, --validate-1, --validate-2, ...
```

### ✅ Do: Group related operations
```bash
--validate  # All validation together
--deploy    # All deployment together
```

---

## Summary

**This is THE STANDARD for all scripts.**

Every script in `~/.claude/scripts/` must:
1. Support `--json` and `--raw` output modes
2. Support `--full` and section flags
3. Have 3-5 logical sections
4. Auto-flow when successful
5. Pause for LLM intervention only when needed (1-2 points max)
6. Return structured JSON with `next_steps`

This pattern gives us:
- ✅ Speed: Auto-flow eliminates babysitting
- ✅ Intelligence: LLM intervenes when needed
- ✅ Debuggability: --raw mode for deep dives
- ✅ Composability: Section flags for resuming

**Use this template. Follow this standard. Apply to all future scripts.**

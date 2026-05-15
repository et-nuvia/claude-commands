# Script Authoring Guide

## Pattern: Smart Scripts, Simple Commands

Scripts contain **all logic** — config reading, validation, JSON output with `next_action`.

## Script Template

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (define BEFORE sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)        echo "display_summary" ;;
        ready_for_opus) echo "use_opus_model" ;;
        *)              _default_map_status_to_action "$1" ;;
    esac
}

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"  # log(), exit_with_json(), colors
source "${SCRIPT_DIR}/lib/yaml.sh"               # yaml_get(), yaml_get_default()

# --- Config ---
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MY_CONFIG=$(yaml_get_default '.path.to.value' 'default' "${PROJECT_ROOT}/PROJECT.yaml")

# --- Flag Parsing ---
OUTPUT_MODE="json"
SECTION="full"
while [[ $# -gt 0 ]]; do
    case $1 in
        --json) OUTPUT_MODE="json"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --identify) SECTION="identify"; shift ;;
        --full) SECTION="full"; shift ;;
        *) break ;;
    esac
done

# --- Section Functions ---
section_identify() {
    log "${BLUE}Identifying...${NC}"
    # ... logic ...
    if [[ "$SECTION" == "identify" ]]; then
        exit_with_json "success" "Identified" "" '"key": "value"'
    fi
}

# --- Main ---
case "$SECTION" in
    identify) section_identify ;;
    full) section_identify; section_analyze ;;
esac
```

## Shared Libraries

| Library | Provides | When to Use |
|---------|----------|-------------|
| `lib/output-framework.sh` | `log()`, `log_json()`, `exit_with_json()`, colors | Every script |
| `lib/logging.sh` | `log_info()`, `log_success()`, `log_error()`, `log_warn()`, `log_debug()` | Auto-sourced by output-framework |
| `lib/yaml.sh` | `yaml_get()`, `yaml_get_default()`, `yaml_get_array()` | Any script reading PROJECT.yaml |
| `lib/project-knowledge.sh` | `pk_exists()`, `pk_load_full()`, `pk_load_section()` | Feature review, audit, planning |
| `lib/task-tracker-sync.sh` | `tracker_detect()`, `tracker_sync_status()`, `tracker_sync_comment()` | Task close, hold, resume |
| `lib/branching.sh` | `get_feature_branch_prefix()`, `create_feature_branch()`, `detect_merge_target()` | Task start, branch setup |
| `lib/git-utils.sh` | `detect_base_branch()`, `get_default_branch()`, `is_protected_branch()` | Git operations |
| `lib/common.sh` | `print_error()`, `require_command()`, `die()`, `trim()` | Generator/utility scripts |

## Requirements

1. **`next_action` in every JSON response** — maps status to agent directive
2. **Auto-read PROJECT.yaml via `yaml_get()`** — never use `yq` directly (cross-platform issues)
3. **`--json` / `--raw` modes** — JSON for agents, raw for debugging
4. **Section-based execution** — `--full` runs all, `--sectionN` runs one
5. **Centralized JSON output** — use `exit_with_json()` from output-framework, not inline
6. **Source guard** — all libraries use `[[ -n "${_LIB_LOADED:-}" ]] && return 0` pattern

## Section Flag Naming Convention

- **First section**: `--identify` (load task context, validate inputs)
- **Analysis sections**: verb-based (`--analyze`, `--verify`, `--test`)
- **Output sections**: `--report`, `--generate`, `--cleanup`
- **Run all**: `--full` (default)

## PROJECT.yaml Handling

| Category | Scripts | Behavior if Missing |
|----------|---------|-------------------|
| **Required** | task-start, task-continue, task-fetch, task-close, task-risk, deploy-to-stage, deploy-to-prod | Exit with clear error |
| **Optional** | task-capture, task-design, task-audit, task-hold, task-resume, task-summary, task-code-review | Use defaults, don't mention |

## next_action Mapping

Standard values:
- `display_summary` — success, show results
- `fix_error` — error, show message and debug instructions
- `confirm_action` — needs user decision
- `resolve_conflicts` — merge/rebase conflicts
- `parse_content` — LLM must analyze/synthesize content
- `sync_asana` — MCP operations needed
- `use_opus_model` — switch to Opus for analysis
- `generate_plan` / `generate_document` / `generate_report` — create output
- `build_project_knowledge` — create PROJECT-KNOWLEDGE.md
- `verify_implementation` — run 100-point verification
- `analyze_code` — LLM code review
- `cleanup` — run cleanup phase
- `continue` — proceed to next phase

## Valid Status Values

`success` | `error` | `needs_decision` | `ready_for_opus` | `requires_opus` | `blocked` | `ready_for_sync` | `conflict` | `warning` | `skipped` | `ready_for_cleanup` | `ready_for_docs` | `needs_llm` | `intervention_needed` | `review_passed` | `review_failed` | `no_new_files` | `drift_detected` | `needs_knowledge`

## Anti-Patterns (Don't)

- Returning JSON without `next_action`
- Using `yq` directly — always use `yaml_get()` / `yaml_get_default()`
- Scattered inline JSON construction
- Missing `--raw` mode for debugging
- Defining `exit_with_json()` locally — source `output-framework.sh`

## Testing

Every script should be testable via BATS:
```bash
@test "script-name: error path returns fix_error" {
    cd "$TEST_DIR"
    result=$("$SCRIPTS_DIR/script-name.sh" --json --full 2>/dev/null) || true
    [ "$(echo "$result" | jq -r '.next_action')" = "fix_error" ]
}
```

## See Also

- [Command Authoring Guide](command-guide.md) — how to write the companion command
- [Script Template](~/templates/script-template.sh) — copy-paste starter

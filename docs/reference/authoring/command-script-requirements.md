# Command/Script Architecture Requirements

**Version**: 1.0
**Last Updated**: 2026-02-22
**Related Task**: 8AA969-TSK-refactor-command-script-architecture

---

## 1. Verbosity Levels

All scripts MUST support three verbosity levels using standard Unix flags:

### Level 0: Default (Minimal - Token Optimized)
- **No flag required** - this is the default
- JSON output only with minimal fields
- Status, next_action, message, and essential data only
- Example: `~/.claude/scripts/task-start.sh 8AA969`

**Output**:
```json
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Task started on branch feature/8AA969",
  "data": {
    "task_id": "8AA969",
    "branch": "feature/8AA969"
  }
}
```

### Level 1: Verbose (`-v`)
- **Flag**: `-v` or `--verbose`
- JSON output with additional context fields
- Includes what happened and why
- Useful for debugging workflow issues
- Example: `~/.claude/scripts/task-start.sh -v 8AA969`

**Output**:
```json
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Task started on branch feature/8AA969",
  "data": {
    "task_id": "8AA969",
    "branch": "feature/8AA969",
    "previous_branch": "main",
    "asana_task_id": "1234567890",
    "asana_updated": true,
    "uncommitted_changes": false
  },
  "context": {
    "what": "Created feature branch and updated Asana task status to 'In Progress'",
    "why": "Task was in pending status, ready to start work"
  }
}
```

### Level 2: Very Verbose (`-vv`)
- **Flag**: `-vv` or `--debug`
- JSON output with full debugging information
- Includes all intermediate steps, checks performed, config values used
- Full command history and decision tree
- Example: `~/.claude/scripts/task-start.sh -vv 8AA969`

**Output**:
```json
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Task started on branch feature/8AA969",
  "data": {
    "task_id": "8AA969",
    "branch": "feature/8AA969",
    "previous_branch": "main",
    "asana_task_id": "1234567890",
    "asana_updated": true,
    "uncommitted_changes": false
  },
  "context": {
    "what": "Created feature branch and updated Asana task status to 'In Progress'",
    "why": "Task was in pending status, ready to start work"
  },
  "debug": {
    "checks_performed": [
      "Verified task document exists at docs/active/2026-02/8AA969-*.md",
      "Checked git working tree is clean (uncommitted_changes=false)",
      "Validated branch feature/8AA969 does not exist",
      "Checked Asana API connectivity (success)",
      "Retrieved Asana task 1234567890 (status=pending)"
    ],
    "commands_executed": [
      "git status --porcelain",
      "git checkout -b feature/8AA969",
      "curl -H 'Authorization: Bearer ***' https://app.asana.com/api/1.0/tasks/1234567890"
    ],
    "config_used": {
      "asana_workspace": "Engineering",
      "asana_project": "Sprint 2026-02",
      "git_main_branch": "main"
    },
    "timing": {
      "total_ms": 1247,
      "git_operations_ms": 89,
      "asana_api_ms": 1134
    }
  }
}
```

### Implementation Pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

# Default verbosity level
VERBOSITY=0

# Parse verbosity flags
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSITY=1
            shift
            ;;
        -vv|--debug)
            VERBOSITY=2
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Output functions based on verbosity
output_json() {
    local status="$1"
    local next_action="$2"
    local message="$3"
    local data="$4"  # JSON string

    local result="{\"status\":\"$status\",\"next_action\":\"$next_action\",\"message\":\"$message\",\"data\":$data"

    if [[ $VERBOSITY -ge 1 && -n "${CONTEXT:-}" ]]; then
        result="$result,\"context\":$CONTEXT"
    fi

    if [[ $VERBOSITY -ge 2 && -n "${DEBUG:-}" ]]; then
        result="$result,\"debug\":$DEBUG"
    fi

    result="$result}"
    echo "$result"
}
```

---

## 2. PROJECT.yaml Configuration Library

### Design Philosophy
- **One call to get all needed config** - no sequential yq calls
- **Clear error signaling** - agents know exactly what's wrong
- **Schema-aware** - validate paths against PROJECT.yaml schema
- **Flexible** - handle complex conditional resolution (4-5 checks with multiple paths)

### Special Values

Scripts return these special values when config issues occur:

| Value | Meaning | When to Use |
|-------|---------|-------------|
| `__BLANK__` | Path exists but value is empty/null | Value present but not set (e.g., `registry: ""`) |
| `__MISSING__` | Path valid per schema but not present | Optional field not provided (e.g., no `deployment.staging.health_check`) |
| `__INVALID__` | Path not valid according to schema | Typo or non-existent path (e.g., `deployment.stagng.host`) |

### Library Location

**File**: `~/.claude/scripts/lib/project-config.sh`

### Core Function

```bash
#!/usr/bin/env bash
# PROJECT.yaml configuration library
# Provides efficient batch config retrieval with error signaling

# Source this file in scripts:
# source "${SCRIPT_DIR}/lib/project-config.sh"

# Get multiple config values in a single call
# Args: key1=path1 key2=path2 ...
# Returns: JSON with flat structure
#
# Example:
#   get_project_config \
#     staging_host=.deployment.staging.host \
#     staging_port=.deployment.staging.port \
#     registry=.docker.registry
#
# Output:
#   {"staging_host":"192.168.1.10","staging_port":"22","registry":"docker.example.com"}
#
get_project_config() {
    local project_root="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local project_yaml="${project_root}/PROJECT.yaml"

    # If PROJECT.yaml doesn't exist, return all __MISSING__
    if [[ ! -f "$project_yaml" ]]; then
        local result="{"
        local first=true
        for pair in "$@"; do
            local key="${pair%%=*}"
            [[ "$first" == true ]] && first=false || result="$result,"
            result="$result\"$key\":\"__MISSING__\""
        done
        result="$result}"
        echo "$result"
        return 0
    fi

    # Build yq expression to extract all values at once
    local yq_expr="{"
    local first=true

    for pair in "$@"; do
        local key="${pair%%=*}"
        local path="${pair#*=}"

        [[ "$first" == true ]] && first=false || yq_expr="$yq_expr,"
        yq_expr="$yq_expr\"$key\":$path"
    done
    yq_expr="$yq_expr}"

    # Execute yq once to get all values
    local raw_result
    raw_result=$(yq eval -o=json "$yq_expr" "$project_yaml" 2>&1) || {
        # yq failed - likely invalid path
        # Parse error to determine which path failed
        local result="{"
        local first=true
        for pair in "$@"; do
            local key="${pair%%=*}"
            local path="${pair#*=}"

            # Test each path individually to classify error
            local test_result
            test_result=$(yq eval "$path" "$project_yaml" 2>&1) || {
                local error_msg="$test_result"
                local value="__INVALID__"

                # Check if path is valid but missing vs. invalid path
                if [[ "$error_msg" == *"null"* ]] || yq eval "has(${path%.*})" "$project_yaml" 2>/dev/null | grep -q "true"; then
                    value="__MISSING__"
                fi

                [[ "$first" == true ]] && first=false || result="$result,"
                result="$result\"$key\":\"$value\""
                continue
            }

            # Path exists - check if blank
            if [[ -z "$test_result" ]] || [[ "$test_result" == "null" ]]; then
                [[ "$first" == true ]] && first=false || result="$result,"
                result="$result\"$key\":\"__BLANK__\""
            else
                [[ "$first" == true ]] && first=false || result="$result,"
                result="$result\"$key\":$(echo "$test_result" | jq -R .)"
            fi
        done
        result="$result}"
        echo "$result"
        return 0
    }

    # Process successful result to detect __BLANK__ and __MISSING__
    local processed="{"
    local first=true

    for pair in "$@"; do
        local key="${pair%%=*}"
        local value
        value=$(echo "$raw_result" | jq -r ".$key")

        [[ "$first" == true ]] && first=false || processed="$processed,"

        if [[ "$value" == "null" ]]; then
            # Check if path exists in schema (would be __MISSING__ vs __INVALID__)
            local path="${pair#*=}"
            if yq eval "has(${path%.*})" "$project_yaml" 2>/dev/null | grep -q "true"; then
                processed="$processed\"$key\":\"__MISSING__\""
            else
                processed="$processed\"$key\":\"__INVALID__\""
            fi
        elif [[ -z "$value" ]]; then
            processed="$processed\"$key\":\"__BLANK__\""
        else
            processed="$processed\"$key\":$(echo "$value" | jq -R .)"
        fi
    done
    processed="$processed}"

    echo "$processed"
}

# Export functions
export -f get_project_config

# NOTE: Only create domain-specific helpers when 2+ scripts request the EXACT same data.
# Use analyze-config-usage.sh to detect duplicate patterns automatically.
# Each script should implement its own conditional logic using get_project_config().
# This keeps the library simple and gives scripts maximum flexibility.
```

### Usage in Scripts

#### Example 1: Simple config retrieval with validation

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"

# Get all needed config in ONE call
CONFIG=$(get_project_config \
    staging_host=.deployment.staging.host \
    staging_port=.deployment.staging.port \
    prod_host=.deployment.production.host \
    registry=.docker.registry \
    db_host=.database.host)

# Extract values
STAGING_HOST=$(echo "$CONFIG" | jq -r '.staging_host')
STAGING_PORT=$(echo "$CONFIG" | jq -r '.staging_port')
REGISTRY=$(echo "$CONFIG" | jq -r '.registry')

# Check for special values
if [[ "$STAGING_HOST" == "__MISSING__" ]]; then
    echo "Error: deployment.staging.host not configured in PROJECT.yaml" >&2
    exit 1
elif [[ "$STAGING_HOST" == "__INVALID__" ]]; then
    echo "Error: Invalid path .deployment.staging.host in PROJECT.yaml schema" >&2
    exit 1
elif [[ "$STAGING_HOST" == "__BLANK__" ]]; then
    echo "Error: deployment.staging.host is empty in PROJECT.yaml" >&2
    exit 1
fi

# Use values...
```

#### Example 2: Conditional resolution with fallback paths (RECOMMENDED)

**Get ALL fields (primary + fallback) in ONE call, then use simple if/else logic:**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"

ENV="${1:-staging}"

# ONE call - get primary AND all fallback paths upfront
CONFIG=$(get_project_config \
    primary_host=".deployment.${ENV}.host" \
    primary_port=".deployment.${ENV}.port" \
    primary_user=".deployment.${ENV}.user" \
    fallback1_host=".infrastructure.${ENV}.ip" \
    fallback1_port=".infrastructure.${ENV}.ssh_port" \
    fallback1_user=".infrastructure.${ENV}.user" \
    fallback2_host=".servers.${ENV}.address" \
    fallback2_port=".servers.${ENV}.port" \
    fallback2_user=".deployment.ssh_user")

# Simple conditional logic - all data already available
HOST=$(echo "$CONFIG" | jq -r '.primary_host')
PORT=$(echo "$CONFIG" | jq -r '.primary_port')
USER=$(echo "$CONFIG" | jq -r '.primary_user')

# Fallback #1 if primary missing
if [[ "$HOST" == "__MISSING__" ]] || [[ "$HOST" == "__INVALID__" ]]; then
    HOST=$(echo "$CONFIG" | jq -r '.fallback1_host')
    PORT=$(echo "$CONFIG" | jq -r '.fallback1_port')
    USER=$(echo "$CONFIG" | jq -r '.fallback1_user')
fi

# Fallback #2 if fallback1 also missing
if [[ "$HOST" == "__MISSING__" ]] || [[ "$HOST" == "__INVALID__" ]]; then
    HOST=$(echo "$CONFIG" | jq -r '.fallback2_host')
    PORT=$(echo "$CONFIG" | jq -r '.fallback2_port')
    USER=$(echo "$CONFIG" | jq -r '.fallback2_user')
fi

# Error if all paths failed
if [[ "$HOST" == "__MISSING__" ]] || [[ "$HOST" == "__INVALID__" ]] || [[ "$HOST" == "__BLANK__" ]]; then
    output_json "error" "fix_config" "Could not find deployment host for $ENV" \
        "{\"env\":\"$ENV\",\"tried_paths\":[\"deployment.$ENV.host\",\"infrastructure.$ENV.ip\",\"servers.$ENV.address\"]}"
    exit 1
fi

# Use values - guaranteed valid at this point
ssh -p "$PORT" "$USER@$HOST" "echo 'Connected'"
```

**Why this is better:**
- ✅ **One PROJECT.yaml call** (not 2-3 separate calls)
- ✅ **All data available upfront** - no repeated yq executions
- ✅ **Simple if/else logic** - easy to understand and debug
- ✅ **Faster execution** - significant performance improvement
- ✅ **Better for -vv mode** - can report all paths checked in one debug block

---

## 3. Detecting Duplicate Patterns

### Auto-Detection Script

**File**: `scripts/analyze-config-usage.sh`

**Purpose**:
1. **Find duplicate patterns** across scripts → suggest new helpers to create
2. **Verify scripts use existing helpers** → catch agents creating patterns from scratch
3. **Run as pre-commit hook** → prevent divergent code from being committed

**Must be REALLY fast** (< 1 second) since it runs on every commit.

**Usage**:
```bash
# Full scan - find duplicates and suggest new helpers
~/.claude/scripts/analyze-config-usage.sh --full

# Verification mode (pre-commit hook) - check scripts use existing helpers
~/.claude/scripts/analyze-config-usage.sh --verify

# Check specific files only (for git pre-commit)
~/.claude/scripts/analyze-config-usage.sh --verify scripts/deploy-check.sh scripts/task-start.sh
```

**Example Output**:

**Full scan mode**:
```
=== Duplicate Pattern Analysis ===

Found 3 scripts requesting identical config:
  - scripts/deploy-to-stage.sh
  - scripts/deploy-to-prod.sh
  - scripts/check-deployment.sh

Pattern:
  primary_host=.deployment.{env}.host primary_port=.deployment.{env}.port
  fallback_host=.infrastructure.{env}.ip fallback_port=.infrastructure.{env}.ssh_port

Suggested helper: get_deployment_config(env)
```

**Verification mode** (detects script using pattern manually instead of helper):
```
ERROR: scripts/deploy-check.sh implements pattern matching existing helper

Line 42-48:
  CONFIG=$(get_project_config \
    primary_host=".deployment.staging.host" \
    fallback_host=".infrastructure.staging.ip")

This matches existing helper: get_deployment_config("staging")
Location: scripts/lib/project-config.sh:get_deployment_config()

FIX: Replace manual pattern with helper call
```

**Implementation**:

```bash
#!/usr/bin/env bash
set -euo pipefail

# analyze-config-usage.sh
# Detects duplicate patterns AND verifies scripts use existing helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CACHE_FILE="/tmp/analyze-config-cache-$(git rev-parse --show-toplevel | md5sum | cut -d' ' -f1).json"

MODE="full"
FILES=()

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --full) MODE="full"; shift ;;
        --verify) MODE="verify"; shift ;;
        --cache-only) cat "$CACHE_FILE" 2>/dev/null || echo "{}"; exit 0 ;;
        *) FILES+=("$1"); shift ;;
    esac
done

# ============================================================================
# Step 1: Extract existing helper patterns from lib/project-config.sh
# ============================================================================

extract_helper_patterns() {
    local lib_file="$LIB_DIR/project-config.sh"
    [[ ! -f "$lib_file" ]] && echo "{}" && return

    # Extract function definitions and their get_project_config calls
    # Cache result for speed
    if [[ -f "$CACHE_FILE" ]] && [[ "$lib_file" -ot "$CACHE_FILE" ]]; then
        cat "$CACHE_FILE"
        return
    fi

    local helpers="{}"
    local current_function=""

    while IFS= read -r line; do
        # Detect function start
        if [[ "$line" =~ ^([a-z_]+)\(\) ]]; then
            current_function="${BASH_REMATCH[1]}"
        fi

        # Extract get_project_config pattern within function
        if [[ -n "$current_function" ]] && [[ "$line" =~ get_project_config ]]; then
            # Read multi-line get_project_config call
            local pattern=""
            while IFS= read -r config_line; do
                pattern+=" $config_line"
                [[ "$config_line" =~ \) ]] && break
            done

            # Normalize pattern (remove vars like ${env}, keep structure)
            pattern=$(echo "$pattern" | \
                      sed 's/\${[^}]*}/{VAR}/g' | \
                      tr -d '\n\\' | \
                      sed 's/get_project_config//' | \
                      tr ' ' '\n' | grep '=' | sort | tr '\n' ' ' | xargs)

            # Add to JSON cache
            helpers=$(echo "$helpers" | jq \
                --arg func "$current_function" \
                --arg pat "$pattern" \
                '. + {($func): $pat}')
        fi
    done < "$lib_file"

    echo "$helpers" > "$CACHE_FILE"
    echo "$helpers"
}

HELPER_PATTERNS=$(extract_helper_patterns)

# ============================================================================
# Step 2: Extract patterns from scripts
# ============================================================================

extract_script_pattern() {
    local file="$1"
    local line_num="$2"

    # Extract multi-line get_project_config call starting at line_num
    # Return normalized pattern
    local pattern=""
    local current_line=$line_num

    while IFS= read -r config_line; do
        pattern+=" $config_line"
        [[ "$config_line" =~ \) ]] && break
        ((current_line++))
    done < <(tail -n +$line_num "$file")

    # Normalize (replace variables with {VAR} placeholder)
    pattern=$(echo "$pattern" | \
              sed 's/"\$[^"]*"/{VAR}/g' | \
              sed 's/\${[^}]*}/{VAR}/g' | \
              tr -d '\n\\' | \
              sed 's/get_project_config//' | \
              tr ' ' '\n' | grep '=' | sort | tr '\n' ' ' | xargs)

    echo "$pattern"
}

# ============================================================================
# Step 3: Verify mode - check scripts use existing helpers
# ============================================================================

verify_scripts() {
    local files=("$@")
    local exit_code=0

    # If no files specified, scan changed files in git
    if [[ ${#files[@]} -eq 0 ]]; then
        mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM | grep '\.sh$')
    fi

    for file in "${files[@]}"; do
        [[ ! -f "$file" ]] && continue

        # Find get_project_config calls
        while IFS=: read -r line_num line_content; do
            # Extract pattern
            pattern=$(extract_script_pattern "$file" "$line_num")

            # Check if matches existing helper
            while IFS= read -r helper_func; do
                helper_pattern=$(echo "$HELPER_PATTERNS" | jq -r ".$helper_func")

                if [[ "$pattern" == "$helper_pattern" ]]; then
                    echo "ERROR: $file line $line_num implements pattern matching existing helper" >&2
                    echo >&2
                    echo "Pattern found:" >&2
                    sed -n "${line_num},$((line_num + 5))p" "$file" | sed 's/^/  /' >&2
                    echo >&2
                    echo "This matches existing helper: $helper_func()" >&2
                    echo "Location: scripts/lib/project-config.sh:$helper_func()" >&2
                    echo >&2
                    echo "FIX: Replace manual pattern with helper call" >&2
                    echo "---" >&2
                    exit_code=1
                fi
            done < <(echo "$HELPER_PATTERNS" | jq -r 'keys[]')

        done < <(grep -n 'get_project_config' "$file")
    done

    return $exit_code
}

# ============================================================================
# Step 4: Full scan mode - find duplicates across all scripts
# ============================================================================

full_scan() {
    local scripts_dir="${1:-$SCRIPT_DIR}"
    declare -A PATTERNS
    declare -A PATTERN_FILES

    # Scan all scripts
    while IFS= read -r script; do
        # Skip lib directory
        [[ "$script" =~ /lib/ ]] && continue

        # Extract patterns
        while IFS=: read -r line_num _; do
            pattern=$(extract_script_pattern "$script" "$line_num")

            # Hash pattern for grouping
            pattern_hash=$(echo "$pattern" | md5sum | cut -d' ' -f1)

            # Track pattern and files
            PATTERNS["$pattern_hash"]="$pattern"
            PATTERN_FILES["$pattern_hash"]="${PATTERN_FILES[$pattern_hash]:-}$script:$line_num "
        done < <(grep -n 'get_project_config' "$script")

    done < <(find "$scripts_dir" -name "*.sh" -type f)

    # Report duplicates (2+ scripts using same pattern)
    echo "=== Duplicate Config Pattern Analysis ==="
    echo

    local found_duplicates=false

    for hash in "${!PATTERNS[@]}"; do
        pattern="${PATTERNS[$hash]}"
        files="${PATTERN_FILES[$hash]}"
        count=$(echo "$files" | wc -w)

        if [[ $count -ge 2 ]]; then
            found_duplicates=true
            echo "Found $count scripts requesting identical config:"
            echo "$files" | tr ' ' '\n' | sed 's/^/  - /'
            echo
            echo "Pattern:"
            echo "  $pattern"
            echo
            echo "Suggested helper: extract this to a function in lib/project-config.sh"
            echo "---"
            echo
        fi
    done

    if [[ "$found_duplicates" == false ]]; then
        echo "No duplicate patterns found - all scripts have unique config needs."
    fi
}

# ============================================================================
# Main
# ============================================================================

case "$MODE" in
    verify)
        verify_scripts "${FILES[@]}"
        exit $?
        ;;
    full)
        full_scan "${FILES[0]:-}"
        ;;
esac
```

**Performance Optimizations** (must be < 1 second):
- ✅ **Cache helper patterns** - only re-extract when lib/project-config.sh changes
- ✅ **Only scan changed files** in verify mode (git diff --cached)
- ✅ **Pattern hashing** - fast comparison using md5sum
- ✅ **JSON cache** - helper patterns cached to /tmp
- ✅ **Early exit** - stop reading file after pattern extracted

**When to create helpers:**
- ✅ **2+ scripts** request the exact same config paths
- ✅ **Same fallback logic** across multiple scripts
- ✅ **Complex conditional resolution** that's repeated

**When NOT to create helpers:**
- ❌ Pattern only used in 1 script
- ❌ Similar but not identical patterns (different paths)
- ❌ Simple single-value lookups

### Pre-Commit Hook Setup

**File**: `.git/hooks/pre-commit`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Run config pattern verification on staged .sh files
echo "Verifying config patterns..."

if ! ~/.claude/scripts/analyze-config-usage.sh --verify; then
    echo
    echo "❌ COMMIT BLOCKED: Scripts implement patterns matching existing helpers"
    echo
    echo "You MUST update scripts to use helpers instead of manual patterns."
    echo "This cannot be bypassed - divergent code is not allowed."
    echo
    echo "To see all available helpers:"
    echo "  ~/.claude/scripts/analyze-config-usage.sh --cache-only | jq -r 'keys[]'"
    echo
    echo "To view helper implementation:"
    echo "  grep -A 20 'function_name()' ~/.claude/scripts/lib/project-config.sh"
    echo
    exit 1
fi

echo "✓ Config patterns verified"
```

**Make executable**:
```bash
chmod +x .git/hooks/pre-commit
```

**Benefits**:
- ✅ **Prevents divergent code** - agents can't create duplicate patterns
- ✅ **Enforces helper usage** - automatic detection and blocking
- ✅ **Fast** - only scans changed files (< 1 second)
- ✅ **Educational** - shows which helper to use in error message
- ✅ **No bypass** - must fix the issue to commit (intentional enforcement)

---

## 4. Output Control & Standardization

### Critical Rules

1. **NO OUTPUT BLEED** - Agents must only see what they should see
2. **Verbosity-aware output** - Level 0 returns minimal JSON, Level 2 returns everything
3. **Capture all intermediate output** - Don't let it leak to stdout/stderr
4. **Standardized JSON structure** - Consistent across all scripts
5. **Flexible enough for 100+ commands** - Not too rigid

### Output Capture Pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

# Redirect all script output to /dev/null by default
# Only final JSON should go to stdout
exec 3>&1  # Save stdout to fd 3
exec 4>&2  # Save stderr to fd 4

# Function to capture command output without leaking
run_quiet() {
    local cmd="$1"
    local output
    local exit_code

    if [[ $VERBOSITY -ge 2 ]]; then
        # Level 2: Capture and include in debug
        output=$(eval "$cmd" 2>&1) || exit_code=$?
        DEBUG_COMMANDS+=("{\"cmd\":\"$cmd\",\"output\":$(echo "$output" | jq -Rs .),\"exit_code\":${exit_code:-0}}")
    elif [[ $VERBOSITY -ge 1 ]]; then
        # Level 1: Capture but don't include (just for error reporting)
        output=$(eval "$cmd" 2>&1) || exit_code=$?
        [[ ${exit_code:-0} -ne 0 ]] && ERRORS+=("$cmd failed: $output")
    else
        # Level 0: Discard output entirely
        eval "$cmd" >/dev/null 2>&1 || exit_code=$?
    fi

    return ${exit_code:-0}
}

# Example usage
run_quiet "git status --porcelain"
run_quiet "curl -s https://app.asana.com/api/1.0/tasks/123"
```

### Standardized JSON Output

All scripts return this structure:

```json
{
  "status": "success|error|needs_input|needs_decision",
  "next_action": "display_summary|resolve_conflicts|fix_error|confirm_action",
  "message": "Brief human-readable summary",
  "data": {
    "field1": "value1",
    "field2": "value2"
  },
  "context": {  // Only if VERBOSITY >= 1
    "what": "What happened",
    "why": "Why it happened"
  },
  "debug": {  // Only if VERBOSITY >= 2
    "checks_performed": [...],
    "commands_executed": [...],
    "config_used": {...},
    "timing": {...}
  }
}
```

---

## 5. Unit Testing with BATS

### Testing Framework: BATS (Bash Automated Testing System)

**Installation**:
```bash
# macOS
brew install bats-core

# Ubuntu/Debian
sudo apt-get install bats

# Manual (if needed)
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

### Test Organization

```
scripts/
├── tests/
│   ├── test_helper.bash          # Shared test utilities
│   ├── test_project_config.bats  # PROJECT.yaml library tests
│   ├── test_task_start.bats      # task-start.sh tests
│   ├── test_deploy_stage.bats    # deploy-to-stage.sh tests
│   └── fixtures/
│       ├── PROJECT.yaml.minimal
│       ├── PROJECT.yaml.full
│       └── PROJECT.yaml.invalid
```

### Test Requirements

Every script MUST have:

1. **Unit tests** for core functions
2. **Integration tests** for complete workflows
3. **Error case tests** for all failure modes
4. **Verbosity tests** for all 3 levels
5. **Output capture tests** to ensure no bleed
6. **PROJECT.yaml tests** with __MISSING__, __BLANK__, __INVALID__ cases

### Example Test File

```bash
#!/usr/bin/env bats
# Test suite for task-start.sh

load test_helper

setup() {
    # Create temp workspace for each test
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create minimal PROJECT.yaml
    cp "$BATS_TEST_DIRNAME/fixtures/PROJECT.yaml.minimal" PROJECT.yaml

    # Create mock task document
    mkdir -p docs/active/2026-02
    cat > docs/active/2026-02/8AA969-2602222045-TSK-test.md << 'EOF'
# Task: test
**Work Item**: 8AA969
**Folder**: docs/active/2026-02
**Created**: 2026-02-22 20:45
**Status**: Active
EOF
}

teardown() {
    # Cleanup temp workspace
    rm -rf "$TEST_DIR"
}

@test "task-start: success path with default verbosity" {
    run ~/.claude/scripts/task-start.sh 8AA969

    assert_success
    assert_output --partial '"status":"success"'
    assert_output --partial '"next_action":"display_summary"'

    # Should NOT include context or debug at level 0
    refute_output --partial '"context"'
    refute_output --partial '"debug"'
}

@test "task-start: verbose output includes context" {
    run ~/.claude/scripts/task-start.sh -v 8AA969

    assert_success
    assert_output --partial '"context"'
    assert_output --partial '"what"'
    assert_output --partial '"why"'

    # Should NOT include debug at level 1
    refute_output --partial '"debug"'
}

@test "task-start: debug output includes full details" {
    run ~/.claude/scripts/task-start.sh -vv 8AA969

    assert_success
    assert_output --partial '"debug"'
    assert_output --partial '"checks_performed"'
    assert_output --partial '"commands_executed"'
    assert_output --partial '"config_used"'
}

@test "task-start: handles __MISSING__ config gracefully" {
    # Remove deployment section from PROJECT.yaml
    yq eval 'del(.deployment)' -i PROJECT.yaml

    run ~/.claude/scripts/task-start.sh 8AA969

    # Should still succeed (deployment config optional for task-start)
    assert_success
}

@test "task-start: no output bleed at default verbosity" {
    # Capture all output
    run ~/.claude/scripts/task-start.sh 8AA969

    # Should be valid JSON only
    echo "$output" | jq . > /dev/null
    assert_success

    # Should NOT contain raw git/curl output
    refute_output --partial "On branch"
    refute_output --partial "HTTP/1.1"
}

@test "task-start: error path returns proper structure" {
    # Try to start non-existent task
    run ~/.claude/scripts/task-start.sh NONEXIST

    assert_failure
    assert_output --partial '"status":"error"'
    assert_output --partial '"next_action":"fix_error"'
    assert_output --partial "Task document not found"
}
```

### Test Helper Functions

**File**: `scripts/tests/test_helper.bash`

```bash
# BATS test helper functions

# Assert functions
assert_success() {
    if [[ "$status" -ne 0 ]]; then
        echo "Expected success but got exit code $status" >&2
        echo "Output: $output" >&2
        return 1
    fi
}

assert_failure() {
    if [[ "$status" -eq 0 ]]; then
        echo "Expected failure but got success" >&2
        echo "Output: $output" >&2
        return 1
    fi
}

assert_output() {
    local flag="$1"
    local expected="$2"

    case "$flag" in
        --partial)
            if [[ "$output" != *"$expected"* ]]; then
                echo "Expected output to contain: $expected" >&2
                echo "Actual output: $output" >&2
                return 1
            fi
            ;;
        *)
            if [[ "$output" != "$flag" ]]; then
                echo "Expected output: $flag" >&2
                echo "Actual output: $output" >&2
                return 1
            fi
            ;;
    esac
}

refute_output() {
    local flag="$1"
    local expected="$2"

    case "$flag" in
        --partial)
            if [[ "$output" == *"$expected"* ]]; then
                echo "Expected output NOT to contain: $expected" >&2
                echo "Actual output: $output" >&2
                return 1
            fi
            ;;
        *)
            if [[ "$output" == "$flag" ]]; then
                echo "Expected output NOT to be: $flag" >&2
                return 1
            fi
            ;;
    esac
}

# Mock helpers
mock_asana_api() {
    # Create mock curl that returns canned Asana responses
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
}

create_mock_project_yaml() {
    local type="${1:-minimal}"
    cp "$BATS_TEST_DIRNAME/fixtures/PROJECT.yaml.$type" PROJECT.yaml
}
```

### Running Tests

```bash
# Run all tests
bats scripts/tests/

# Run specific test file
bats scripts/tests/test_task_start.bats

# Run with verbose output
bats -t scripts/tests/test_task_start.bats

# Run and stop on first failure
bats -T scripts/tests/
```

---

## 6. Script Quality Requirements

Every script MUST:

### Rock Solid
- [ ] Exit code 0 on success, non-zero on error
- [ ] Handle all error cases gracefully
- [ ] Validate all inputs before use
- [ ] No undefined variable usage (`set -u`)
- [ ] No command failures ignored (`set -e`)
- [ ] Proper error messages with context

### Smart & Token Optimized
- [ ] Default verbosity level 0 (minimal JSON)
- [ ] Only return data relevant to next_action
- [ ] Batch config reads (one PROJECT.yaml call)
- [ ] No unnecessary API calls
- [ ] Cache expensive operations when possible

### No Output Bleed
- [ ] All intermediate output captured
- [ ] Only final JSON to stdout
- [ ] Errors to stderr only at -v/-vv
- [ ] No raw command output leaking
- [ ] Clean JSON parseable by jq

### Standardized
- [ ] Consistent JSON structure
- [ ] Standard status values
- [ ] Standard next_action values
- [ ] Consistent error format
- [ ] Predictable behavior

### Flexible
- [ ] Works with or without PROJECT.yaml
- [ ] Sensible defaults when config missing
- [ ] Handles __MISSING__/__BLANK__/__INVALID__ gracefully
- [ ] Adapts to different environments
- [ ] Compatible with 100+ different commands

---

## 7. Migration Validation Checklist

For each migrated command/script pair:

### Command File
- [ ] < 150 lines total
- [ ] ≤ 3 bash blocks
- [ ] No jq parsing code
- [ ] No case statements on status
- [ ] No decision tree logic
- [ ] No field extraction patterns
- [ ] Documents workflow only
- [ ] Documents next_action values
- [ ] Includes 2-3 usage examples
- [ ] Explains -v/-vv debugging

### Script File
- [ ] Auto-reads PROJECT.yaml using lib/project-config.sh
- [ ] Returns next_action field
- [ ] Supports -v flag (verbosity level 1)
- [ ] Supports -vv flag (verbosity level 2)
- [ ] All config via flags (no env vars)
- [ ] Returns minimal data at level 0
- [ ] Handles decision logic internally
- [ ] Concise errors by default
- [ ] No output bleed
- [ ] Uses run_quiet() for all commands

### Testing
- [ ] BATS test file exists
- [ ] Success path tested
- [ ] Error path tested
- [ ] All 3 verbosity levels tested
- [ ] Output capture tested (no bleed)
- [ ] PROJECT.yaml __MISSING__/__BLANK__/__INVALID__ tested
- [ ] Integration test passes
- [ ] All tests pass

### Quality
- [ ] Script is rock solid (handles all errors)
- [ ] Token optimized (minimal output at level 0)
- [ ] Smart (batches config reads, caches expensive ops)
- [ ] Standardized (follows JSON schema)
- [ ] Flexible (works with different configs)

---

## 8. Common Patterns

### Pattern: Deploy to Environment

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"

# Parse args
VERBOSITY=0
ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSITY=1; shift ;;
        -vv|--debug) VERBOSITY=2; shift ;;
        staging|production) ENV="$1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ONE call - get all deployment paths (primary + fallbacks)
CONFIG=$(get_project_config \
    primary_host=".deployment.${ENV}.host" \
    primary_port=".deployment.${ENV}.port" \
    primary_user=".deployment.${ENV}.user" \
    primary_method=".deployment.${ENV}.method" \
    fallback_host=".infrastructure.${ENV}.ip" \
    fallback_port=".infrastructure.${ENV}.ssh_port" \
    fallback_user=".infrastructure.${ENV}.user" \
    fallback_method=".deployment.method" \
    health_check=".deployment.${ENV}.health_check_url")

# Extract primary values
HOST=$(echo "$CONFIG" | jq -r '.primary_host')
PORT=$(echo "$CONFIG" | jq -r '.primary_port')
USER=$(echo "$CONFIG" | jq -r '.primary_user')
METHOD=$(echo "$CONFIG" | jq -r '.primary_method')

# Use fallback if primary missing
if [[ "$HOST" == "__MISSING__" ]] || [[ "$HOST" == "__INVALID__" ]]; then
    HOST=$(echo "$CONFIG" | jq -r '.fallback_host')
    PORT=$(echo "$CONFIG" | jq -r '.fallback_port')
    USER=$(echo "$CONFIG" | jq -r '.fallback_user')
    METHOD=$(echo "$CONFIG" | jq -r '.fallback_method')
fi

# Validate - error if still missing
if [[ "$HOST" == "__MISSING__" ]] || [[ "$HOST" == "__INVALID__" ]] || [[ "$HOST" == "__BLANK__" ]]; then
    output_json "error" "fix_config" "Deployment host not configured for $ENV" \
        "{\"env\":\"$ENV\",\"tried_paths\":[\"deployment.$ENV.host\",\"infrastructure.$ENV.ip\"]}"
    exit 1
fi

# Execute deployment
run_quiet "ssh -p $PORT $USER@$HOST 'docker compose pull && docker compose up -d'"

# Return success
output_json "success" "verify_deployment" "Deployed to $ENV" \
    "{\"env\":\"$ENV\",\"host\":\"$HOST\",\"method\":\"$METHOD\"}"
```

### Pattern: Task Operation

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"

# Parse args
VERBOSITY=0
TASK_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSITY=1; shift ;;
        -vv|--debug) VERBOSITY=2; shift ;;
        *) TASK_ID="$1"; shift ;;
    esac
done

# Get task config
CONFIG=$(get_project_config \
    asana_workspace=.task_management.asana.workspace_id \
    asana_project=.task_management.asana.default_project)

# Find task document
TASK_DOC=$(find_by_sequence "$TASK_ID") || {
    output_json "error" "fix_error" "Task $TASK_ID not found" \
        "{\"task_id\":\"$TASK_ID\"}"
    exit 1
}

# Perform operation
run_quiet "git checkout -b feature/$TASK_ID"

# Update Asana if configured
ASANA_WORKSPACE=$(echo "$CONFIG" | jq -r '.asana_workspace')
if [[ "$ASANA_WORKSPACE" != "__MISSING__" ]]; then
    run_quiet "curl -H 'Authorization: Bearer $ASANA_TOKEN' ..."
fi

# Return success
output_json "success" "display_summary" "Task $TASK_ID started" \
    "{\"task_id\":\"$TASK_ID\",\"branch\":\"feature/$TASK_ID\"}"
```

---

## 9. Command File (.md) Requirements

Command files are the LLM-facing workflow descriptions in `~/.claude/commands/`. They tell the agent **what to do**, while scripts handle **how to do it**.

### Structure Requirements

- **Maximum 150 lines** (target: 50-100 lines)
- **Maximum 3 bash blocks**:
  1. Execute the script and parse JSON response
  2. Handle response statuses (success/error/needs_input)
  3. Optional: debugging examples
- **No JSON parsing logic** - no `jq` extraction, no field-by-field parsing
- **No decision trees** - script returns `next_action`, command follows it
- **No case statements on data fields** - only on `status` and `next_action`

### Required Sections

```markdown
---
name: command-name
description: One-line description
user_invocable: true
---

You are a [role]. Your job is to [primary purpose].

## Step 1: Execute

\`\`\`bash
RESULT=$(~/.claude/scripts/command-name.sh [args])
STATUS=$(echo "$RESULT" | jq -r '.status')
NEXT_ACTION=$(echo "$RESULT" | jq -r '.next_action')
\`\`\`

## Step 2: Handle Response

Based on `next_action`:
- `display_summary` - Show the user what happened
- `confirm_action` - Ask user before proceeding
- `fix_error` - Show error, suggest fix
- [other actions specific to this command]

## Step 3: [Follow-up if needed]

## Related Commands
```

### What Commands Must NOT Do

- Parse multi-field JSON responses (script should return only what's needed)
- Implement retry logic (script handles retries internally)
- Make direct API calls (script wraps all external calls)
- Contain environment detection logic (script reads PROJECT.yaml)
- Include verbose workflow examples (1-2 short examples max)

---

## 10. next_action Values

All scripts return a `next_action` field that tells the LLM what to do next. These are **not a strict standard** - scripts should use whatever value clearly describes the next step. But when two scripts genuinely mean the same thing, reuse the same value.

### Common Values (reuse when they fit)

| next_action | Meaning |
|-------------|---------|
| `display_summary` | Show results to user |
| `fix_error` | Something failed, show error |
| `fix_config` | PROJECT.yaml needs updating |
| `confirm_action` | Ask user before proceeding |
| `needs_input` | Missing required information |
| `verify_deployment` | Check health after deploy |
| `read_plan_and_work` | Read PLN, do next task |

### Conventions

- Use `snake_case`
- Keep names self-descriptive - the LLM should understand without documentation
- Check existing scripts before inventing a new value - if one already means what you need, use it
- Don't force-fit a value just for consistency - clarity beats uniformity

---

## Summary

This document defines the complete requirements for the "smart scripts, simple commands" architecture:

1. **Verbosity** (Section 1) - Three levels: default (minimal), -v (context), -vv (debug)
2. **Config** (Section 2) - One-call batch retrieval with __MISSING__/__BLANK__/__INVALID__
3. **Duplicates** (Section 3) - Auto-detection prevents divergent patterns
4. **Output** (Section 4) - No bleed, JSON only, verbosity-aware
5. **Testing** (Section 5) - BATS for all scripts, 3 verbosity levels tested
6. **Quality** (Section 6) - Rock solid, token optimized, no bleed, standardized
7. **Checklist** (Section 7) - Per-command validation for migration
8. **Patterns** (Section 8) - Deploy and task operation templates
9. **Commands** (Section 9) - 150 lines max, 3 bash blocks, no parsing
10. **next_action** (Section 10) - Standard values across all scripts

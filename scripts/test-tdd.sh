#!/usr/bin/env bash
#
# test-tdd.sh - Generate failing tests for TDD workflow (RED phase)
#
# This script consolidates the test-tdd command logic into a single
# reusable script with JSON/raw output modes.
#
# Usage:
#   test-tdd.sh --json --full                 # Full workflow with JSON output
#   test-tdd.sh --json --detect-framework     # Just detect framework
#   test-tdd.sh --json --generate [context]   # Generate tests
#   test-tdd.sh --raw --<section>             # Verbose debugging output
#
# JSON Response Format:
#   {
#     "status": "success|error|ready_for_generation",
#     "section": "detect|generate|verify|commit",
#     "message": "Human-readable summary",
#     "timestamp": "ISO 8601 datetime",
#     "framework": "pytest|jest|vitest|go|...",
#     "test_file": "path/to/test_file",
#     "tests_created": 5,
#     "test_names": ["test_1", "test_2", ...],
#     "fixtures_created": ["fixture_1", ...],
#     "all_failed": true,
#     "next_steps": ["Step 1", "Step 2", ...],
#     "details": "Additional context"
#   }

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_MODE="${OUTPUT_MODE:-json}"  # json or raw
SECTION="test-tdd"

source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# ============================================================================
# Output Functions (delegates to output-framework)
# ============================================================================

output_json() {
  local status="$1"
  local section_name="$2"
  local message="$3"
  shift 3

  local json="{\"status\":\"$status\",\"section\":\"$section_name\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\""

  # Add optional fields
  while [[ $# -gt 0 ]]; do
    json="$json,\"$1\":$2"
    shift 2
  done

  json="$json}"
  log_json "$json"
}

output() {
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json "$@"
  else
    echo "$@"
  fi
}

error_exit() {
  local section_name="$1"
  local message="$2"
  local details="${3:-}"

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    local json="{\"status\":\"error\",\"section\":\"$section_name\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\""
    if [[ -n "$details" ]]; then
      details=$(echo "$details" | jq -Rs .)
      json="$json,\"details\":$details"
    fi
    json="$json}"
    log_json "$json"
  else
    echo "Error in section '$section_name': $message" >&2
    if [[ -n "$details" ]]; then
      echo "Details: $details" >&2
    fi
  fi
  exit 1
}

# ============================================================================
# Section Functions
# ============================================================================

detect_framework() {
  local framework=""
  local details=""

  # Check PROJECT.yaml first
  if [[ -f "PROJECT.yaml" ]]; then
    framework=$(yaml_get '.testing.command' PROJECT.yaml)
    if [[ -n "$framework" ]]; then
      case "$framework" in
        pytest*) framework="pytest" ;;
        *jest*) framework="jest" ;;
        *vitest*) framework="vitest" ;;
        "npm test")
          # Check package.json for framework
          if [[ -f "package.json" ]]; then
            if jq -e '.devDependencies.jest // .dependencies.jest' package.json >/dev/null 2>&1; then
              framework="jest"
            elif jq -e '.devDependencies.vitest // .dependencies.vitest' package.json >/dev/null 2>&1; then
              framework="vitest"
            fi
          fi
          ;;
        "go test") framework="go" ;;
      esac
      details="Detected from PROJECT.yaml"
    fi
  fi

  # Auto-detect if not found in PROJECT.yaml
  if [[ -z "$framework" ]]; then
    # Python
    if [[ -f "requirements.txt" ]] && grep -q "pytest" requirements.txt; then
      framework="pytest"
      details="Detected from requirements.txt"
    elif [[ -f "pyproject.toml" ]] && grep -q "pytest" pyproject.toml; then
      framework="pytest"
      details="Detected from pyproject.toml"
    # TypeScript/JavaScript
    elif [[ -f "package.json" ]]; then
      if jq -e '.devDependencies.jest // .dependencies.jest' package.json >/dev/null 2>&1; then
        framework="jest"
        details="Detected from package.json"
      elif jq -e '.devDependencies.vitest // .dependencies.vitest' package.json >/dev/null 2>&1; then
        framework="vitest"
        details="Detected from package.json"
      elif jq -e '.devDependencies.mocha // .dependencies.mocha' package.json >/dev/null 2>&1; then
        framework="mocha"
        details="Detected from package.json"
      fi
    # Go
    elif [[ -f "go.mod" ]]; then
      framework="go"
      details="Detected from go.mod"
    fi
  fi

  if [[ -z "$framework" ]]; then
    error_exit "detect" "Unable to detect testing framework" "Check PROJECT.yaml or add framework dependencies"
  fi

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json "success" "detect" "Framework detected: $framework" \
      "framework" "\"$framework\"" \
      "details" "\"$details\""
  else
    echo "Framework: $framework"
    echo "Source: $details"
  fi
}

load_task_context() {
  local task_doc=""
  local plan_doc=""
  local context=""

  # Check for .current-task file
  if [[ -f ".current-task" ]]; then
    task_doc=$(grep "^task_doc=" .current-task 2>/dev/null | cut -d= -f2- || true)

    if [[ -n "$task_doc" ]] && [[ -f "$task_doc" ]]; then
      context=$(cat "$task_doc")

      # Look for linked plan document
      plan_doc=$(echo "$context" | sed -n 's/.*Plan: \(.*\.md\).*/\1/p' || echo "")

      if [[ -n "$plan_doc" ]] && [[ -f "$plan_doc" ]]; then
        context="$context

=== PLAN DOCUMENT ===
$(cat "$plan_doc")"
      fi
    fi
  fi

  if [[ -n "$context" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      # Escape context for JSON
      local escaped_context=$(echo "$context" | jq -Rs .)
      output_json "ready_for_generation" "context" "Task context loaded" \
        "task_doc" "\"$task_doc\"" \
        "plan_doc" "\"$plan_doc\"" \
        "context" "$escaped_context"
    else
      echo "Task: $task_doc"
      if [[ -n "$plan_doc" ]]; then
        echo "Plan: $plan_doc"
      fi
      echo ""
      echo "$context"
    fi
  else
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      output_json "ready_for_generation" "context" "No task context found - ready for manual input" \
        "task_doc" "null" \
        "plan_doc" "null" \
        "context" "null"
    else
      echo "No current task found (.current-task file missing)"
      echo "Ready for manual test specification"
    fi
  fi
}

get_test_location() {
  local framework="$1"
  local module="${2:-}"
  local test_file=""

  case "$framework" in
    pytest)
      if [[ -d "tests" ]]; then
        test_file="tests/test_${module}.py"
      elif [[ -d "src" ]] && [[ -d "src/tests" ]]; then
        test_file="src/tests/test_${module}.py"
      else
        test_file="tests/test_${module}.py"
      fi
      ;;
    jest|vitest)
      if [[ -d "__tests__" ]]; then
        test_file="__tests__/${module}.test.ts"
      elif [[ -d "tests" ]]; then
        test_file="tests/${module}.test.ts"
      else
        test_file="src/${module}.test.ts"
      fi
      ;;
    go)
      if [[ -n "$module" ]]; then
        test_file="${module}_test.go"
      else
        test_file="main_test.go"
      fi
      ;;
    *)
      test_file="tests/test_${module}"
      ;;
  esac

  echo "$test_file"
}

# ============================================================================
# Main Workflow
# ============================================================================

run_full_workflow() {
  # This is a hybrid command - script handles detection and setup,
  # LLM handles test generation (creativity required)

  # Section 1: Detect framework
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== Detecting Testing Framework ==="
  fi

  local framework_result
  framework_result=$(OUTPUT_MODE=json detect_framework) || true
  if [[ "$(echo "$framework_result" | jq -r '.status')" == "error" ]]; then
    echo "$framework_result"
    exit 1
  fi
  local framework=$(echo "$framework_result" | jq -r '.framework')

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Framework: $framework"
    echo ""
  fi

  # Section 2: Load task context (if available)
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== Loading Task Context ==="
  fi

  local context_result=$(OUTPUT_MODE=json load_task_context)
  local task_doc=$(echo "$context_result" | jq -r '.task_doc')
  local context=$(echo "$context_result" | jq -r '.context')

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    if [[ "$task_doc" != "null" ]]; then
      echo "Task: $task_doc"
      echo "Context loaded"
    else
      echo "No task context - manual input needed"
    fi
    echo ""
  fi

  # Return ready_for_generation status - LLM will generate tests
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json "ready_for_generation" "full" "Framework detected, ready for test generation" \
      "framework" "\"$framework\"" \
      "task_doc" $(if [[ "$task_doc" != "null" ]]; then echo "\"$task_doc\""; else echo "null"; fi) \
      "context" $(if [[ "$context" != "null" ]]; then echo "$context" | jq -Rs .; else echo "null"; fi) \
      "next_steps" "[\"LLM generates test code based on framework and context\",\"Create test file\",\"Run tests to verify RED phase\",\"Commit tests\"]"
  else
    echo "=== Ready for Test Generation ==="
    echo "Framework: $framework"
    echo "LLM should now generate test code"
  fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  local mode="full"

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        OUTPUT_MODE="json"
        shift
        ;;
      --raw)
        OUTPUT_MODE="raw"
        shift
        ;;
      --full)
        mode="full"
        shift
        ;;
      --detect-framework|--detect)
        mode="detect"
        shift
        ;;
      --load-context|--context)
        mode="context"
        shift
        ;;
      --help|-h)
        cat <<EOF
Usage: test-tdd.sh [OPTIONS]

Generate failing tests for TDD workflow (RED phase)

OPTIONS:
  --json              Structured output (default; TOON for AI callers, JSON otherwise)
  --raw               Output in raw/verbose format
  --full              Run full workflow (detect + load context)
  --detect-framework  Only detect testing framework
  --load-context      Only load task context
  --help              Show this help message

EXAMPLES:
  # Full workflow with JSON output
  test-tdd.sh --json --full

  # Detect framework only
  test-tdd.sh --json --detect-framework

  # Debug mode with verbose output
  test-tdd.sh --raw --full

WORKFLOW:
  1. Detect testing framework (pytest, jest, go, etc.)
  2. Load task context (if .current-task exists)
  3. Return ready_for_generation status
  4. LLM generates test code based on framework
  5. LLM creates test file
  6. LLM runs tests to verify RED phase
  7. LLM commits tests

NOTE: This is a hybrid script - it handles detection/setup,
      LLM handles creative test generation.
EOF
        exit 0
        ;;
      *)
        error_exit "parse" "Unknown option: $1" "Run with --help for usage"
        ;;
    esac
  done

  # Execute based on mode
  case "$mode" in
    full)
      run_full_workflow
      ;;
    detect)
      detect_framework
      ;;
    context)
      load_task_context
      ;;
    *)
      error_exit "parse" "Unknown mode: $mode"
      ;;
  esac
}

main "$@"

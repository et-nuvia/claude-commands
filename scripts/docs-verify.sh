#!/usr/bin/env bash
# docs-verify.sh - Verify documentation matches code behavior
# Usage: ./scripts/docs-verify.sh [--json|--raw] [--full|--analyze|--verify|--test-examples] [--scope-path <path>]
# Returns: JSON with verification results or raw output
# Exit codes: 0=success, 1=error

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

OUTPUT_MODE="json"  # json or raw
RUN_ANALYZE=false
RUN_VERIFY=false
RUN_TEST_EXAMPLES=false
SCOPE_PATH=""

# ============================================================================
# Parse Arguments
# ============================================================================

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
      RUN_ANALYZE=true
      RUN_VERIFY=true
      RUN_TEST_EXAMPLES=true
      shift
      ;;
    --analyze)
      RUN_ANALYZE=true
      shift
      ;;
    --verify)
      RUN_VERIFY=true
      shift
      ;;
    --test-examples)
      RUN_TEST_EXAMPLES=true
      shift
      ;;
    --scope-path)
      SCOPE_PATH="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--json|--raw] [--full|--analyze|--verify|--test-examples] [--scope-path <path>]

Verify documentation matches code behavior.

Options:
  --json              Output structured JSON (default)
  --raw               Output verbose debugging information
  --full              Run all verification sections
  --analyze           Analyze code changes
  --verify            Verify documentation accuracy
  --test-examples     Test code examples in documentation
  --scope-path <path> Optional path to scope verification (file or directory)

Exit codes:
  0 - Verification successful or issues found and reported
  1 - Critical error occurred
  2 - Invalid usage
EOF
      exit 0
      ;;
    *)
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo '{"status":"error","section":"args","message":"Unknown option: '"$1"'","details":"Run with --help for usage"}' >&2
      else
        echo "❌ Unknown option: $1" >&2
        echo "Run with --help for usage" >&2
      fi
      exit 2
      ;;
  esac
done

# If no sections specified, run full verification
if [[ "$RUN_ANALYZE" == "false" && "$RUN_VERIFY" == "false" && "$RUN_TEST_EXAMPLES" == "false" ]]; then
  RUN_ANALYZE=true
  RUN_VERIFY=true
  RUN_TEST_EXAMPLES=true
fi

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "ℹ️  $*" >&2
  fi
}

log_success() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "✓ $*" >&2
  fi
}

log_error() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "❌ $*" >&2
  fi
}

log_warning() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "⚠️  $*" >&2
  fi
}

# Escape JSON strings
json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n'
}

# ============================================================================
# Section: Analyze Code Changes
# ============================================================================

analyze_code_changes() {
  local section_status="success"
  local section_details=""
  local changed_files=()
  local doc_files=()

  log_info "Analyzing code changes..."

  # Determine scope
  if [[ -n "$SCOPE_PATH" ]]; then
    log_info "Scope: $SCOPE_PATH"

    if [[ -f "$SCOPE_PATH" ]]; then
      # Single file
      changed_files=("$SCOPE_PATH")
    elif [[ -d "$SCOPE_PATH" ]]; then
      # Directory - find all files
      while IFS= read -r file; do
        changed_files+=("$file")
      done < <(find "$SCOPE_PATH" -type f \( -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.go" -o -name "*.rs" \))
    else
      section_status="error"
      section_details="Path not found: $SCOPE_PATH"
      log_error "$section_details"
    fi
  else
    # Get changed files from git
    log_info "Analyzing all changes since origin/main"

    if git rev-parse --verify origin/main >/dev/null 2>&1; then
      while IFS= read -r file; do
        if [[ -f "$file" ]]; then
          changed_files+=("$file")
        fi
      done < <(git diff --name-only origin/main...HEAD 2>/dev/null || echo "")

      if [[ ${#changed_files[@]} -eq 0 ]]; then
        section_details="No changes detected since origin/main"
        log_info "$section_details"
      fi
    else
      section_status="error"
      section_details="Cannot find origin/main branch"
      log_error "$section_details"
    fi
  fi

  # Find documentation files
  log_info "Finding documentation files..."

  while IFS= read -r file; do
    doc_files+=("$file")
  done < <(find . -type f \( -name "README.md" -o -name "*.md" \) -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/venv/*" | sort)

  log_success "Found ${#doc_files[@]} documentation files"
  log_success "Found ${#changed_files[@]} changed files"

  # Build JSON output
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    # Build changed_files array
    local changed_files_json="[]"
    if [[ ${#changed_files[@]} -gt 0 ]]; then
      changed_files_json="[$(printf '"%s",' "${changed_files[@]}" | sed 's/,$//')"]"
    fi

    # Build doc_files array
    local doc_files_json="[]"
    if [[ ${#doc_files[@]} -gt 0 ]]; then
      doc_files_json="[$(printf '"%s",' "${doc_files[@]}" | sed 's/,$//')"]"
    fi

    cat <<EOF
{
  "section": "analyze",
  "status": "$section_status",
  "changed_files_count": ${#changed_files[@]},
  "doc_files_count": ${#doc_files[@]},
  "changed_files": $changed_files_json,
  "doc_files": $doc_files_json,
  "details": "$(json_escape "$section_details")",
  "scope": "$(json_escape "$SCOPE_PATH")"
}
EOF
  else
    echo ""
    echo "═══════════════════════════════════════"
    echo "Analysis Results"
    echo "═══════════════════════════════════════"
    echo ""
    echo "Changed files: ${#changed_files[@]}"
    for file in "${changed_files[@]}"; do
      echo "  - $file"
    done
    echo ""
    echo "Documentation files: ${#doc_files[@]}"
    for file in "${doc_files[@]}"; do
      echo "  - $file"
    done
    echo ""
  fi

  return 0
}

# ============================================================================
# Section: Verify Documentation
# ============================================================================

verify_documentation() {
  local section_status="requires_llm"
  local section_details=""

  log_info "Verifying documentation accuracy..."

  # This section requires LLM to analyze code-documentation alignment
  section_details="This step requires LLM analysis to compare code behavior with documentation. The LLM should:
1. Read changed code files
2. Read documentation files
3. Identify discrepancies (outdated, missing, incorrect information)
4. Update documentation to match code behavior
5. Verify inline docstrings match implementation"

  log_info "$section_details"

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    cat <<EOF
{
  "section": "verify",
  "status": "$section_status",
  "message": "LLM intervention required for code-documentation analysis",
  "details": "$(json_escape "$section_details")",
  "next_steps": [
    "Use Opus model for deep code-documentation analysis",
    "Read changed code files",
    "Read documentation files",
    "Identify discrepancies",
    "Update documentation using Edit tool"
  ]
}
EOF
  else
    echo ""
    echo "═══════════════════════════════════════"
    echo "Documentation Verification"
    echo "═══════════════════════════════════════"
    echo ""
    echo "$section_details"
    echo ""
    echo "Next steps:"
    echo "1. Use Opus model for analysis"
    echo "2. Read changed code files"
    echo "3. Read documentation files"
    echo "4. Identify discrepancies"
    echo "5. Update documentation"
    echo ""
  fi

  return 0
}

# ============================================================================
# Section: Test Examples
# ============================================================================

test_examples() {
  local section_status="success"
  local section_details=""
  local examples_found=0
  local examples_tested=0
  local examples_passed=0
  local examples_failed=0

  log_info "Testing code examples in documentation..."

  # Find markdown files with code blocks
  local doc_files=()
  while IFS= read -r file; do
    doc_files+=("$file")
  done < <(find . -type f -name "*.md" -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/venv/*" | sort)

  log_info "Scanning ${#doc_files[@]} markdown files for code examples..."

  # Count code blocks
  for doc in "${doc_files[@]}"; do
    if [[ -f "$doc" ]]; then
      local blocks=$(grep -c '```' "$doc" 2>/dev/null || echo "0")
      examples_found=$((examples_found + blocks / 2))
    fi
  done

  log_info "Found approximately $examples_found code examples"

  section_details="Found $examples_found code examples in ${#doc_files[@]} documentation files. Testing requires:
1. Extracting code blocks from markdown
2. Running Python examples in Docker
3. Type-checking TypeScript examples
4. Testing shell/curl commands
5. Verifying examples produce expected output"

  # Note: Full example testing requires LLM to extract and test each example
  section_status="requires_llm"

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    cat <<EOF
{
  "section": "test-examples",
  "status": "$section_status",
  "message": "Code example testing requires LLM assistance",
  "examples_found": $examples_found,
  "doc_files_scanned": ${#doc_files[@]},
  "details": "$(json_escape "$section_details")",
  "next_steps": [
    "Extract code blocks from markdown files",
    "Test Python examples in Docker container",
    "Type-check TypeScript examples",
    "Verify examples work as documented",
    "Update broken examples"
  ]
}
EOF
  else
    echo ""
    echo "═══════════════════════════════════════"
    echo "Example Testing"
    echo "═══════════════════════════════════════"
    echo ""
    echo "Examples found: $examples_found (across ${#doc_files[@]} files)"
    echo ""
    echo "$section_details"
    echo ""
    echo "Next steps:"
    echo "1. Extract code blocks"
    echo "2. Test Python examples in Docker"
    echo "3. Type-check TypeScript examples"
    echo "4. Verify examples work"
    echo "5. Update broken examples"
    echo ""
  fi

  return 0
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  local overall_status="success"
  local sections_run=0
  local sections_completed=0
  local results=()

  # Run requested sections
  if [[ "$RUN_ANALYZE" == "true" ]]; then
    sections_run=$((sections_run + 1))
    if analyze_result=$(analyze_code_changes); then
      sections_completed=$((sections_completed + 1))
      results+=("$analyze_result")
    else
      overall_status="error"
      results+=('{"section":"analyze","status":"error","message":"Analysis failed"}')
    fi
  fi

  if [[ "$RUN_VERIFY" == "true" ]]; then
    sections_run=$((sections_run + 1))
    if verify_result=$(verify_documentation); then
      sections_completed=$((sections_completed + 1))
      results+=("$verify_result")
      overall_status="requires_llm"
    else
      overall_status="error"
      results+=('{"section":"verify","status":"error","message":"Verification failed"}')
    fi
  fi

  if [[ "$RUN_TEST_EXAMPLES" == "true" ]]; then
    sections_run=$((sections_run + 1))
    if test_result=$(test_examples); then
      sections_completed=$((sections_completed + 1))
      results+=("$test_result")
      if [[ "$overall_status" != "error" ]]; then
        overall_status="requires_llm"
      fi
    else
      overall_status="error"
      results+=('{"section":"test-examples","status":"error","message":"Example testing failed"}')
    fi
  fi

  # Output final result
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    # Combine section results
    local sections_json="[$(IFS=,; echo "${results[*]}")]"

    cat <<EOF
{
  "status": "$overall_status",
  "message": "Documentation verification analysis complete",
  "sections_run": $sections_run,
  "sections_completed": $sections_completed,
  "sections": $sections_json,
  "timestamp": "$(date -Iseconds)"
}
EOF
  else
    echo ""
    echo "═══════════════════════════════════════"
    echo "Documentation Verification Complete"
    echo "═══════════════════════════════════════"
    echo ""
    echo "Status: $overall_status"
    echo "Sections run: $sections_run"
    echo "Sections completed: $sections_completed"
    echo ""
    echo "Summary:"
    echo "- Analysis provides file lists for LLM review"
    echo "- Verification requires LLM to analyze code-doc alignment"
    echo "- Example testing requires LLM to extract and test examples"
    echo ""
    echo "Next: Use Opus model to perform deep analysis and updates"
    echo ""
  fi

  # Exit based on status
  if [[ "$overall_status" == "error" ]]; then
    exit 1
  fi

  exit 0
}

# ============================================================================
# Execute
# ============================================================================

main

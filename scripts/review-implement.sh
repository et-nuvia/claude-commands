#!/usr/bin/env bash
set -euo pipefail

# review-implement.sh - Prepare data for implementing code review or task list fixes
# Outputs structured JSON for command to parse and guide LLM

# Default values
OUTPUT_MODE="json"
SECTION="full"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        ready_for_implementation) echo "implement_changes" ;;
        success)                  echo "display_summary" ;;
        *)                        _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Usage function
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] --document <document_path>

Analyze a code review, implementation plan, or task document and prepare
structured data for implementing fixes.

OPTIONS:
  --json          Structured output (default; TOON for AI callers, JSON otherwise)
  --raw           Output raw text format for debugging
  --full          Run full analysis (default)
  --parse         Parse document only (extract items)
  --validate      Validate document structure only
  -h, --help      Show this help message

ARGUMENTS:
  document_path   Path to document (code review, plan, or task)

EXAMPLES:
  # Full analysis with JSON output
  $(basename "$0") --json --full docs/code-reviews/2024-02-20-review.md

  # Parse items only
  $(basename "$0") --json --parse docs/plans/2024-02-19-plan.md

  # Debugging with raw output
  $(basename "$0") --raw --parse docs/tasks/2024-02-18-task.md

DOCUMENT TYPES:
  - Code reviews:        docs/code-reviews/*.md
  - Implementation plans: docs/plans/*.md
  - Parsed issues:       docs/tasks/*.md
  - Task documents:      docs/active/*-TSK-*.md

JSON OUTPUT STRUCTURE:
  {
    "status": "success|error",
    "section": "parse|validate|full",
    "message": "Human-readable summary",
    "timestamp": "ISO 8601 datetime",
    "document": {
      "path": "path/to/document.md",
      "type": "code_review|plan|task|issue",
      "title": "Document title",
      "created": "date from filename"
    },
    "items": [
      {
        "id": "C1 or Task 1.1 or criterion number",
        "type": "critical|major|minor|task|criterion",
        "title": "Item description",
        "priority": "high|medium|low",
        "file_references": ["src/file.py:42"],
        "details": "Implementation details"
      }
    ],
    "summary": {
      "total_items": 10,
      "critical": 2,
      "major": 3,
      "minor": 5
    }
  }

ERROR STATUS:
  {
    "status": "error",
    "section": "parse|validate|full",
    "message": "Error description",
    "details": "Detailed error information"
  }
EOF
  exit 0
}

# Parse arguments
DOCUMENT_PATH=""
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
      SECTION="full"
      shift
      ;;
    --parse)
      SECTION="parse"
      shift
      ;;
    --validate)
      SECTION="validate"
      shift
      ;;
    -h|--help)
      usage
      ;;
    --document)
      DOCUMENT_PATH="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# JSON output helper (delegates to output-framework)
output_json() {
  local status="$1"
  local section_name="$2"
  local message="$3"
  local details="${4:-}"

  local next_action
  next_action=$(map_status_to_action "$status")

  log_json "$(cat <<EOF
{
  "status": "$status",
  "section": "$section_name",
  "message": "$message",
  "next_action": "$next_action",
  "timestamp": "$(date -Iseconds)",
  "details": "$details"
}
EOF
)"
}

# Validate document path
if [[ -z "$DOCUMENT_PATH" ]]; then
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json "error" "$SECTION" "No document path provided" "Usage: $(basename "$0") [OPTIONS] --document <document_path>"
  else
    echo "Error: No document path provided"
    echo ""
    usage
  fi
  exit 1
fi

if [[ ! -f "$DOCUMENT_PATH" ]]; then
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json "error" "$SECTION" "Document not found" "File does not exist: $DOCUMENT_PATH"
  else
    echo "Error: Document not found: $DOCUMENT_PATH"
  fi
  exit 1
fi

# Detect document type
detect_document_type() {
  local path="$1"
  local basename_file
  basename_file=$(basename "$path")

  # Check by directory
  if [[ "$path" == *"/code-reviews/"* ]] || [[ "$path" == *"CRV"* ]]; then
    echo "code_review"
  elif [[ "$path" == *"/plans/"* ]] || [[ "$path" == *"PLN"* ]] || [[ "$path" == *"IMP"* ]]; then
    echo "plan"
  elif [[ "$path" == *"/tasks/"* ]] || [[ "$path" == *"TSK"* ]]; then
    echo "task"
  elif [[ "$path" == *"FND"* ]]; then
    echo "findings"
  else
    # Infer from content if needed
    echo "unknown"
  fi
}

# Parse document to extract actionable items
parse_document() {
  local path="$1"
  local doc_type="$2"

  # Read document content
  local content
  content=$(cat "$path")

  # Parse based on type
  case "$doc_type" in
    code_review)
      # Extract issues: C1, M1, m1 pattern
      # Critical (C#), Major (M#), Minor (m#)
      parse_code_review "$content"
      ;;
    plan)
      # Extract tasks: Phase X, Task X.Y pattern
      parse_plan "$content"
      ;;
    task)
      # Extract acceptance criteria and checklist items
      parse_task "$content"
      ;;
    *)
      # Generic parsing - look for numbered lists, checkboxes
      parse_generic "$content"
      ;;
  esac
}

parse_code_review() {
  local content="$1"

  # Extract title (first # heading)
  local title
  title=$(echo "$content" | grep -m 1 "^# " | sed 's/^# //' || echo "Code Review")

  # Extract overall score if present
  local score
  score=$(echo "$content" | grep -i "overall score" | grep -oE "[0-9]+(\.[0-9]+)?(/10)?" | head -1 || echo "N/A")

  # Count issues by type
  local critical_count major_count minor_count
  critical_count=$(echo "$content" | grep -cE "^(###)?\s*C[0-9]+" || echo "0")
  major_count=$(echo "$content" | grep -cE "^(###)?\s*M[0-9]+" || echo "0")
  minor_count=$(echo "$content" | grep -cE "^(###)?\s*m[0-9]+" || echo "0")

  # Build JSON items array (simplified - full parsing would be more complex)
  cat <<EOF
{
  "title": "$title",
  "score": "$score",
  "items": [],
  "summary": {
    "total_items": $((critical_count + major_count + minor_count)),
    "critical": $critical_count,
    "major": $major_count,
    "minor": $minor_count
  }
}
EOF
}

parse_plan() {
  local content="$1"

  # Extract title
  local title
  title=$(echo "$content" | grep -m 1 "^# " | sed 's/^# //' || echo "Implementation Plan")

  # Count tasks (Task X.Y pattern)
  local task_count
  task_count=$(echo "$content" | grep -cE "^(###)?\s*(Task|Phase) [0-9]+(\.[0-9]+)?" || echo "0")

  cat <<EOF
{
  "title": "$title",
  "items": [],
  "summary": {
    "total_items": $task_count,
    "completed": 0,
    "pending": $task_count
  }
}
EOF
}

parse_task() {
  local content="$1"

  # Extract title
  local title
  title=$(echo "$content" | grep -m 1 "^# " | sed 's/^# //' || echo "Task Document")

  # Count acceptance criteria (checkboxes)
  local criteria_count
  criteria_count=$(echo "$content" | grep -cE "^- \[(x| )\]" || echo "0")

  cat <<EOF
{
  "title": "$title",
  "items": [],
  "summary": {
    "total_items": $criteria_count,
    "completed": 0,
    "pending": $criteria_count
  }
}
EOF
}

parse_generic() {
  local content="$1"

  # Extract title
  local title
  title=$(echo "$content" | grep -m 1 "^# " | sed 's/^# //' || echo "Document")

  # Count items (any numbered or checkbox list)
  local item_count
  item_count=$(echo "$content" | grep -cE "^([0-9]+\.|[-*] \[(x| )\])" || echo "0")

  cat <<EOF
{
  "title": "$title",
  "items": [],
  "summary": {
    "total_items": $item_count
  }
}
EOF
}

# Main execution
main() {
  local doc_type
  doc_type=$(detect_document_type "$DOCUMENT_PATH")

  # Section-based execution
  case "$SECTION" in
    validate)
      # Just check if document is valid
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "validate",
  "message": "Document is valid",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "document": {
    "path": "$DOCUMENT_PATH",
    "type": "$doc_type",
    "exists": true,
    "readable": true
  }
}
EOF
      else
        echo "✓ Document is valid"
        echo "Path: $DOCUMENT_PATH"
        echo "Type: $doc_type"
      fi
      ;;

    parse)
      # Parse and extract items
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        local parsed_data
        parsed_data=$(parse_document "$DOCUMENT_PATH" "$doc_type")

        cat <<EOF
{
  "status": "success",
  "section": "parse",
  "message": "Document parsed successfully",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "document": {
    "path": "$DOCUMENT_PATH",
    "type": "$doc_type"
  },
  "parsed_data": $parsed_data
}
EOF
      else
        echo "✓ Document parsed"
        echo "Path: $DOCUMENT_PATH"
        echo "Type: $doc_type"
        echo ""
        parse_document "$DOCUMENT_PATH" "$doc_type"
      fi
      ;;

    full)
      # Full analysis - parse and prepare for implementation
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        local parsed_data
        parsed_data=$(parse_document "$DOCUMENT_PATH" "$doc_type")

        cat <<EOF
{
  "status": "ready_for_implementation",
  "section": "full",
  "message": "Document analyzed and ready for implementation guidance",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "document": {
    "path": "$DOCUMENT_PATH",
    "type": "$doc_type"
  },
  "parsed_data": $parsed_data,
  "next_steps": [
    "LLM should read the document",
    "Extract actionable items based on type",
    "Present items to user with multi-select options",
    "For each selected item, propose implementation approaches (2-3 options)",
    "Generate implementation plan using EnterPlanMode",
    "Execute implementation with test-driven approach"
  ]
}
EOF
      else
        echo "✓ Document analyzed"
        echo "Path: $DOCUMENT_PATH"
        echo "Type: $doc_type"
        echo ""
        echo "Parsed data:"
        parse_document "$DOCUMENT_PATH" "$doc_type"
        echo ""
        echo "Next steps:"
        echo "1. Read document and extract actionable items"
        echo "2. Present items to user for selection"
        echo "3. Propose implementation approaches"
        echo "4. Generate implementation plan"
        echo "5. Execute implementation"
      fi
      ;;

    *)
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        output_json "error" "$SECTION" "Unknown section" "Valid sections: validate, parse, full"
      else
        echo "Error: Unknown section: $SECTION"
      fi
      exit 1
      ;;
  esac
}

# Execute main
main

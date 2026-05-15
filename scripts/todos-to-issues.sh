#!/usr/bin/env bash
set -euo pipefail

# todos-to-issues.sh - Convert TODO comments to GitHub issues
# Usage: todos-to-issues.sh [--json|--raw] [--full|--validate|--scan|--create]

MODE="json"; SECTION="all"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

OUTPUT_MODE="$MODE"
map_status_to_action() {
    case "$1" in
        success)        echo "display_summary" ;;
        ready_for_llm)  echo "analyze_and_create_issues" ;;
        *)              _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) MODE="json"; OUTPUT_MODE="json"; shift ;;
        --raw) MODE="raw"; OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="all"; shift ;;
        --validate) SECTION="validate"; shift ;;
        --scan) SECTION="scan"; shift ;;
        --create) SECTION="create"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

json_output() {
    local status="$1" section_name="$2" message="$3"; shift 3
    local next_action
    next_action=$(map_status_to_action "$status")
    local ts; ts=$(date -Iseconds)
    if [[ "$MODE" == "json" ]]; then
        local json="{\"status\":\"$status\",\"section\":\"$section_name\",\"message\":\"$message\",\"next_action\":\"$next_action\",\"timestamp\":\"$ts\""
        while [[ $# -gt 0 ]]; do json="$json,$1"; shift; done
        log_json "${json}}"
    else echo "[$status] $section_name: $message"; fi
}

error_exit() {
    json_output "error" "$1" "$2" "${3:-}"
    exit 1
}

validate_github_setup() {
    [[ "$MODE" == "raw" ]] && echo "=== Validating GitHub Setup ===" >&2
    git remote -v 2>/dev/null | grep -q github.com || error_exit "validate" "No GitHub remote found" "\"details\":\"This command requires a GitHub repository\""
    command -v gh &>/dev/null || error_exit "validate" "GitHub CLI not found" "\"details\":\"Install from: https://cli.github.com\""
    gh auth status &>/dev/null || error_exit "validate" "Not authenticated with GitHub" "\"details\":\"Run: gh auth login\""
    [[ "$MODE" == "raw" ]] && echo "✓ GitHub setup validated" >&2
    [[ "$SECTION" == "validate" ]] && { json_output "success" "validate" "GitHub setup validated"; exit 0; }
}

run_preflight_checks() {
    [[ "$MODE" == "raw" ]] && echo "=== Pre-Flight Checks ===" >&2
    local checks_failed=false failed_checks=""
    if [[ -f "PROJECT.yaml" ]]; then
        local test_cmd; test_cmd=$(yaml_get '.testing.test_command' PROJECT.yaml)
        [[ -n "$test_cmd" ]] && ! eval "$test_cmd" &>/dev/null && { checks_failed=true; failed_checks="tests"; [[ "$MODE" == "raw" ]] && echo "✗ Tests failed" >&2; }
        local lint_cmd; lint_cmd=$(yaml_get '.testing.lint_command' PROJECT.yaml)
        [[ -n "$lint_cmd" ]] && ! eval "$lint_cmd" &>/dev/null && { checks_failed=true; failed_checks="${failed_checks:+$failed_checks, }linter"; [[ "$MODE" == "raw" ]] && echo "✗ Linter failed" >&2; }
    fi
    [[ "$checks_failed" == "true" ]] && error_exit "validate" "Pre-flight checks failed: $failed_checks" "\"details\":\"Fix before creating issues\""
    [[ "$MODE" == "raw" ]] && echo "✓ Pre-flight checks passed" >&2
}

scan_todos() {
    [[ "$MODE" == "raw" ]] && echo "=== Scanning for TODOs ===" >&2
    local todo_files
    todo_files=$(rg -l "TODO|FIXME|HACK" --type-not markdown 2>/dev/null || grep -rl "TODO\|FIXME\|HACK" --include="*.py" --include="*.ts" --include="*.js" --include="*.go" . 2>/dev/null || echo "")
    if [[ -z "$todo_files" ]]; then
        json_output "success" "scan" "No TODOs found" "\"todo_count\":0"
        exit 0
    fi
    local todo_count; todo_count=$(echo "$todo_files" | wc -l | tr -d ' ')
    [[ "$MODE" == "raw" ]] && echo "Found TODOs in $todo_count files" >&2
    echo "$todo_files" > /tmp/todos-to-issues-files.txt
    echo "$todo_count" > /tmp/todos-to-issues-count.txt
    if [[ "$SECTION" == "scan" ]]; then
        local files_json; files_json=$(echo "$todo_files" | jq -R . | jq -s . 2>/dev/null || echo "[]")
        json_output "success" "scan" "Found $todo_count files with TODOs" "\"todo_count\":$todo_count,\"files\":$files_json"
        exit 0
    fi
}

prepare_issue_creation() {
    [[ ! -f /tmp/todos-to-issues-files.txt ]] && error_exit "create" "No scan results found" "\"details\":\"Run --scan first\""
    local todo_files; todo_files=$(cat /tmp/todos-to-issues-files.txt)
    local todo_count; todo_count=$(cat /tmp/todos-to-issues-count.txt)
    local files_json; files_json=$(echo "$todo_files" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    json_output "ready_for_llm" "create" "Ready for LLM analysis and issue creation" \
        "\"todo_count\":$todo_count,\"files\":$files_json,\"next_steps\":[\"Read each file\",\"Analyze TODO context\",\"Create GitHub issues using gh CLI\"]"
}

case "$SECTION" in
    all) validate_github_setup; run_preflight_checks; scan_todos; prepare_issue_creation ;;
    validate) validate_github_setup ;;
    scan) validate_github_setup; scan_todos ;;
    create) prepare_issue_creation ;;
    *) error_exit "main" "Invalid section: $SECTION" ;;
esac

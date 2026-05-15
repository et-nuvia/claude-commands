#!/usr/bin/env bash
set -euo pipefail

# format.sh - Format code using project's configured formatter
#
# Usage:
#   ~/.claude/scripts/format.sh [--json|--raw] [--full|--detect|--format|--verify]

# Script directory (needed for sourcing library)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library
source "${SCRIPT_DIR}/lib/output-framework.sh"

OUTPUT_MODE="json"; SECTION="full"; FORMATTER=""; MODIFIED_FILES=""

section_detect() {
    log "Detecting formatter..."
    local detected=""
    { [[ -f "pyproject.toml" ]] && grep -q "ruff" pyproject.toml 2>/dev/null; } && detected="ruff"
    { [[ -z "$detected" ]] && { [[ -f ".prettierrc" ]] || [[ -f ".prettierrc.json" ]] || [[ -f "prettier.config.js" ]]; }; } && detected="prettier"
    { [[ -z "$detected" && -f "package.json" ]] && grep -q "prettier" package.json 2>/dev/null; } && detected="prettier"
    { [[ -z "$detected" && -f "pyproject.toml" ]] && grep -q "black" pyproject.toml 2>/dev/null; } && detected="black"
    [[ -z "$detected" && -f "go.mod" ]] && detected="gofmt"
    [[ -z "$detected" && -f "Cargo.toml" ]] && detected="rustfmt"
    FORMATTER="$detected"
    if [[ -z "$FORMATTER" ]]; then
        exit_with_json "error" "No formatter configuration found" "Consider adding Ruff (Python), Prettier (JS/TS), or appropriate formatter"
    fi
    if [[ "$SECTION" == "detect" ]]; then
        echo "{\"status\":\"success\",\"section\":\"detect\",\"next_action\":\"display_summary\",\"message\":\"Formatter detected: $FORMATTER\",\"formatter\":\"$FORMATTER\",\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi
    log "Detected: $FORMATTER"
}

section_format() {
    log "Formatting files..."
    git rev-parse --git-dir > /dev/null 2>&1 && MODIFIED_FILES=$(git diff --name-only --diff-filter=d HEAD 2>/dev/null || echo "")
    local format_output="" format_status=0
    case "$FORMATTER" in
        ruff)
            [[ -n "$MODIFIED_FILES" ]] && format_output=$(ruff format $MODIFIED_FILES 2>&1) || format_output=$(ruff format . 2>&1) || format_status=$?
            ;;
        prettier)
            [[ -n "$MODIFIED_FILES" ]] && format_output=$(npx prettier --write $MODIFIED_FILES 2>&1) || format_output=$(npx prettier --write . 2>&1) || format_status=$?
            ;;
        black)
            [[ -n "$MODIFIED_FILES" ]] && format_output=$(black $MODIFIED_FILES 2>&1) || format_output=$(black . 2>&1) || format_status=$?
            ;;
        gofmt)
            [[ -n "$MODIFIED_FILES" ]] && format_output=$(gofmt -w $MODIFIED_FILES 2>&1) || format_output=$(gofmt -w . 2>&1) || format_status=$?
            ;;
        rustfmt) format_output=$(cargo fmt 2>&1) || format_status=$? ;;
        *) exit_with_json "error" "Unknown formatter: $FORMATTER" "" ;;
    esac
    if [[ $format_status -ne 0 ]]; then
        exit_with_json "error" "Formatting failed" "$format_output"
    fi
    if [[ "$SECTION" == "format" ]]; then
        echo "{\"status\":\"success\",\"section\":\"format\",\"next_action\":\"display_summary\",\"message\":\"Formatting complete\",\"formatter\":\"$FORMATTER\",\"formatted_output\":$(echo "$format_output" | jq -Rs .),\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi
    log "Formatting complete"
}

section_verify() {
    log "Verifying..."
    local changes=""
    git rev-parse --git-dir > /dev/null 2>&1 && changes=$(git diff --name-only 2>/dev/null || echo "")
    if [[ "$SECTION" == "verify" ]]; then
        echo "{\"status\":\"success\",\"section\":\"verify\",\"next_action\":\"display_summary\",\"message\":\"Verification complete\",\"changes_detected\":$([ -n "$changes" ] && echo "true" || echo "false"),\"changed_files\":$(echo "$changes" | jq -Rs .),\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi
    log "Verification complete"
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --detect) SECTION="detect"; shift ;;
            --format) SECTION="format"; shift ;;
            --verify) SECTION="verify"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done
    case "$SECTION" in
        detect) section_detect ;;
        format) section_detect; section_format ;;
        verify) section_verify ;;
        full)
            section_detect; section_format; section_verify
            echo "{\"status\":\"success\",\"section\":\"full\",\"next_action\":\"display_summary\",\"message\":\"Code formatted successfully\",\"formatter\":\"$FORMATTER\",\"timestamp\":\"$(date -Iseconds)\"}"
            exit 0
            ;;
    esac
}

main "$@"

#!/usr/bin/env bash
#
# makefile-optimize.sh - Audit and upgrade Makefiles against the standard
#
# Usage:
#   makefile-optimize.sh [--json|--raw] [--full|--audit|--fix]
#
# Checks project Makefiles against the Makefile Standard Reference and
# optionally applies auto-fixes for common compliance issues.
#
# Sections:
#   --audit  Check compliance and report findings
#   --fix    Apply auto-fixable improvements
#   --full   Run audit then fix (default)

set -euo pipefail

OUTPUT_MODE="json"
SECTION="full"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --audit) SECTION="audit"; shift ;;
        --fix) SECTION="fix"; shift ;;
        -h|--help)
            echo "Usage: makefile-optimize.sh [--json|--raw] [--full|--audit|--fix]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log() { [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "$@" >&2; }

#------------------------------------------------------------------------------
# Standard targets every project should have (from makefile-standard.md)
#------------------------------------------------------------------------------

REQUIRED_TARGETS=("up" "down" "test" "lint" "format" "typecheck" "clean" "targets")
OPTIONAL_TARGETS=("test-e2e" "test-api" "migrate" "build" "status")

#------------------------------------------------------------------------------
# Find all Makefiles
#------------------------------------------------------------------------------

find_makefiles() {
    local makefiles=()

    if [[ -f "Makefile" ]]; then
        makefiles+=("Makefile")
    fi

    # Check common component directories
    for dir in backend frontend admin api web; do
        if [[ -f "$dir/Makefile" ]]; then
            makefiles+=("$dir/Makefile")
        fi
    done

    echo "${makefiles[@]}"
}

#------------------------------------------------------------------------------
# Check a single Makefile for compliance
#------------------------------------------------------------------------------

check_makefile() {
    local makefile="$1"
    local findings=()
    local score=10

    local content
    content=$(cat "$makefile")

    # Check: FORMAT ?= human
    if ! echo "$content" | grep -q 'FORMAT ?= human'; then
        findings+=("{\"severity\":\"high\",\"issue\":\"Missing FORMAT ?= human\",\"file\":\"$makefile\",\"auto_fixable\":true}")
        score=$((score - 2))
    fi

    # Check: MAKEFLAGS += --no-print-directory
    if ! echo "$content" | grep -q 'MAKEFLAGS.*--no-print-directory'; then
        findings+=("{\"severity\":\"medium\",\"issue\":\"Missing MAKEFLAGS += --no-print-directory\",\"file\":\"$makefile\",\"auto_fixable\":true}")
        score=$((score - 1))
    fi

    # Check: JSON_WRAPPER variable
    if ! echo "$content" | grep -q 'JSON_WRAPPER'; then
        findings+=("{\"severity\":\"high\",\"issue\":\"Missing JSON_WRAPPER variable\",\"file\":\"$makefile\",\"auto_fixable\":true}")
        score=$((score - 2))
    fi

    # Check: FORMAT=json branches
    if ! echo "$content" | grep -q 'ifeq.*FORMAT.*json'; then
        findings+=("{\"severity\":\"high\",\"issue\":\"No FORMAT=json branches found\",\"file\":\"$makefile\",\"auto_fixable\":false}")
        score=$((score - 2))
    fi

    # Check: targets meta-target
    if ! echo "$content" | grep -qE '^targets:'; then
        findings+=("{\"severity\":\"medium\",\"issue\":\"Missing targets meta-target\",\"file\":\"$makefile\",\"auto_fixable\":true}")
        score=$((score - 1))
    fi

    # Check for required targets (root Makefile only)
    if [[ "$makefile" == "Makefile" ]]; then
        for target in "${REQUIRED_TARGETS[@]}"; do
            if ! echo "$content" | grep -qE "^${target}:"; then
                findings+=("{\"severity\":\"low\",\"issue\":\"Missing standard target: $target\",\"file\":\"$makefile\",\"auto_fixable\":false}")
                score=$((score - 1))
            fi
        done
    fi

    # Check: @ prefix on recipe lines (sample check)
    local recipe_lines
    recipe_lines=$(echo "$content" | grep -E '^\t[^@#]' | grep -v 'ifeq\|ifneq\|else\|endif\|include\|export\|define' | head -5 || true)
    if [[ -n "$recipe_lines" ]]; then
        findings+=("{\"severity\":\"low\",\"issue\":\"Some recipe lines missing @ prefix\",\"file\":\"$makefile\",\"auto_fixable\":false}")
    fi

    # Clamp score
    [[ $score -lt 0 ]] && score=0

    echo "$score"
    printf '%s\n' "${findings[@]}"
}

#------------------------------------------------------------------------------
# Section: Audit
#------------------------------------------------------------------------------

section_audit() {
    log "Auditing Makefiles..."

    local makefiles
    read -ra makefiles <<< "$(find_makefiles)"

    if [[ ${#makefiles[@]} -eq 0 ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            echo '{"status":"error","section":"audit","message":"No Makefiles found","next_action":"fix_error","hint":"Run /makefile-init to generate Makefiles"}'
        else
            echo "No Makefiles found. Run /makefile-init to generate." >&2
        fi
        return 1
    fi

    local total_score=0
    local total_files=0
    local all_findings="["
    local first=true

    for makefile in "${makefiles[@]}"; do
        log "Checking $makefile..."
        local result
        result=$(check_makefile "$makefile")

        # First line is score, rest are findings
        local file_score
        file_score=$(echo "$result" | head -1)
        total_score=$((total_score + file_score))
        total_files=$((total_files + 1))

        # Collect findings
        while IFS= read -r finding; do
            [[ -z "$finding" ]] && continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                all_findings="${all_findings},"
            fi
            all_findings="${all_findings}${finding}"
        done <<< "$(echo "$result" | tail -n +2)"
    done

    all_findings="${all_findings}]"

    # Average score
    local avg_score=$((total_score / total_files))

    local status="success"
    local next_action="display_summary"
    local message="Score: $avg_score/10 across $total_files Makefile(s)"

    if [[ $avg_score -lt 8 ]]; then
        # Check if any are auto-fixable
        if echo "$all_findings" | grep -q '"auto_fixable":true'; then
            next_action="fix_before_push"
            message="$message — auto-fixable issues found"
        else
            next_action="confirm_action"
            message="$message — manual changes needed"
        fi
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{"status":"$status","section":"audit","message":"$message","next_action":"$next_action","score":$avg_score,"files_checked":$total_files,"findings":$all_findings,"timestamp":"$(date -Iseconds)"}
EOF
    else
        echo "Makefile Audit: $message"
        echo "$all_findings" | python3 -c "
import sys, json
findings = json.load(sys.stdin)
for f in findings:
    print(f'  [{f[\"severity\"]}] {f[\"file\"]}: {f[\"issue\"]}' + (' (auto-fixable)' if f['auto_fixable'] else ''))
" 2>/dev/null || echo "$all_findings"
    fi
}

#------------------------------------------------------------------------------
# Section: Fix
#------------------------------------------------------------------------------

section_fix() {
    log "Applying auto-fixes..."

    local makefiles
    read -ra makefiles <<< "$(find_makefiles)"

    if [[ ${#makefiles[@]} -eq 0 ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            echo '{"status":"error","section":"fix","message":"No Makefiles found","next_action":"fix_error"}'
        fi
        return 1
    fi

    local fixes_applied=0

    for makefile in "${makefiles[@]}"; do
        local content
        content=$(cat "$makefile")
        local modified=false

        # Fix: Add FORMAT ?= human if missing
        if ! echo "$content" | grep -q 'FORMAT ?= human'; then
            # Add after the first .PHONY line or at top
            local temp_file
            temp_file=$(mktemp)
            if echo "$content" | grep -q '^\.PHONY:'; then
                # Insert after .PHONY line
                awk '/^\.PHONY:/{print; print ""; print "# LLM-optimized output support"; print "FORMAT ?= human"; print "MAKEFLAGS += --no-print-directory"; print "JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh"; next}1' "$makefile" > "$temp_file"
            else
                {
                    echo "# LLM-optimized output support"
                    echo "FORMAT ?= human"
                    echo "MAKEFLAGS += --no-print-directory"
                    echo "JSON_WRAPPER ?= \$(HOME)/.claude/scripts/lib/make-json-wrapper.sh"
                    echo ""
                    cat "$makefile"
                } > "$temp_file"
            fi
            mv "$temp_file" "$makefile"
            modified=true
            fixes_applied=$((fixes_applied + 1))
            log "  Fixed: Added FORMAT/MAKEFLAGS/JSON_WRAPPER to $makefile"
        fi

        # Fix: Add MAKEFLAGS if FORMAT exists but MAKEFLAGS missing
        content=$(cat "$makefile")
        if echo "$content" | grep -q 'FORMAT ?= human' && ! echo "$content" | grep -q 'MAKEFLAGS.*--no-print-directory'; then
            sed -i '/FORMAT ?= human/a MAKEFLAGS += --no-print-directory' "$makefile"
            modified=true
            fixes_applied=$((fixes_applied + 1))
            log "  Fixed: Added MAKEFLAGS to $makefile"
        fi

        # Fix: Add JSON_WRAPPER if missing
        content=$(cat "$makefile")
        if echo "$content" | grep -q 'FORMAT ?= human' && ! echo "$content" | grep -q 'JSON_WRAPPER'; then
            sed -i '/MAKEFLAGS.*--no-print-directory/a JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh' "$makefile"
            modified=true
            fixes_applied=$((fixes_applied + 1))
            log "  Fixed: Added JSON_WRAPPER to $makefile"
        fi

        # Fix: Add targets meta-target if missing
        content=$(cat "$makefile")
        if ! echo "$content" | grep -qE '^targets:'; then
            local component_name
            component_name=$(basename "$(dirname "$(realpath "$makefile")")")
            [[ "$makefile" == "Makefile" ]] && component_name="root"
            cat >> "$makefile" <<MAKETARGET

targets:
ifeq (\$(FORMAT),json)
	@echo '{"status":"success","target":"targets","component":"${component_name}","targets":[]}'
else
	@\$(MAKE) help
endif
MAKETARGET
            modified=true
            fixes_applied=$((fixes_applied + 1))
            log "  Fixed: Added targets meta-target to $makefile"
        fi

        [[ "$modified" == "true" ]] && log "  Updated: $makefile"
    done

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local next_action="display_summary"
        [[ $fixes_applied -eq 0 ]] && next_action="display_summary"
        echo "{\"status\":\"success\",\"section\":\"fix\",\"message\":\"Applied $fixes_applied auto-fix(es)\",\"next_action\":\"$next_action\",\"fixes_applied\":$fixes_applied,\"timestamp\":\"$(date -Iseconds)\"}"
    else
        echo "Applied $fixes_applied auto-fix(es)"
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

case "$SECTION" in
    audit) section_audit ;;
    fix) section_fix ;;
    full) section_audit; section_fix ;;
esac

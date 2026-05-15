#!/usr/bin/env bash
set -euo pipefail

# cleanproject.sh - Clean development artifacts while preserving working code
#
# Usage:
#   cleanproject.sh [--json|--raw] [--full|--identify|--analyze|--cleanup]
#
# Output modes:
#   --json    Structured JSON output (default)
#   --raw     Verbose debugging output
#
# Section flags:
#   --full        Run all sections (default)
#   --identify    Only identify cleanup targets
#   --analyze     Only analyze safety and impact
#   --cleanup     Only perform cleanup (requires --identify and --analyze first)
#
# Examples:
#   cleanproject.sh --json --full              # Complete cleanup with JSON output
#   cleanproject.sh --raw --identify           # Verbose identification of targets
#   cleanproject.sh --json --cleanup           # Resume from cleanup section

# ============================================================================
# Globals
# ============================================================================

OUTPUT_MODE="json"
SECTION="full"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# State tracking
declare -a CLEANUP_TARGETS=()
declare -a PROTECTED_PATTERNS=(
    ".claude"
    ".git"
    "node_modules"
    "vendor"
    ".venv"
    "venv"
    "__pycache__"
    ".next"
    "dist"
    "build"
    ".docker"
)

# ============================================================================
# Output Functions (via output-framework)
# ============================================================================

map_status_to_action() {
    case "$1" in
        success)         echo "display_summary" ;;
        partial_success) echo "fix_failed_files" ;;
        *)               _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

json_output() {
    local status="$1"
    local section_name="$2"
    local message="$3"
    local data="${4:-{}}"

    local next_action
    next_action=$(map_status_to_action "$status")

    log_json "$(cat <<EOF
{
  "status": "$status",
  "section": "$section_name",
  "message": "$message",
  "next_action": "$next_action",
  "data": $data,
  "timestamp": "$(date -Iseconds)"
}
EOF
)"
}

log_info() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "[$(date -u +%H:%M:%S)] [INFO] [$1] ${*:2}" >&2
    fi
}

log_error() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "[$(date -u +%H:%M:%S)] [ERROR] [$1] ${*:2}" >&2
    fi
}

# ============================================================================
# Safety Functions
# ============================================================================

is_protected() {
    local path="$1"

    for pattern in "${PROTECTED_PATTERNS[@]}"; do
        if [[ "$path" == *"$pattern"* ]]; then
            return 0
        fi
    done

    return 1
}

create_checkpoint() {
    log_info "checkpoint" "Creating git checkpoint for safety"

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_info "checkpoint" "Not in git repository, skipping checkpoint"
        return 0
    fi

    if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        git add -A
        git commit -m "chore(clean): pre-cleanup checkpoint" --no-verify 2>/dev/null || {
            log_info "checkpoint" "No changes to commit"
        }
    else
        log_info "checkpoint" "Working tree clean, no checkpoint needed"
    fi
}

# ============================================================================
# Section: Identify Cleanup Targets
# ============================================================================

identify_targets() {
    log_info "identify" "Scanning for cleanup targets"

    local -a temp_files=()
    local -a debug_files=()
    local -a backup_files=()

    # Find temporary files
    while IFS= read -r -d '' file; do
        if ! is_protected "$file"; then
            temp_files+=("$file")
        fi
    done < <(find . -type f \( -name "*.log" -o -name "*.tmp" -o -name "*~" -o -name ".*.swp" \) -print0 2>/dev/null)

    # Find debug files
    while IFS= read -r -d '' file; do
        if ! is_protected "$file"; then
            debug_files+=("$file")
        fi
    done < <(find . -type f \( -name "debug-*" -o -name "*-debug.*" -o -name "*.debug" \) -print0 2>/dev/null)

    # Find backup files
    while IFS= read -r -d '' file; do
        if ! is_protected "$file"; then
            backup_files+=("$file")
        fi
    done < <(find . -type f \( -name "*.bak" -o -name "*.backup" -o -name "*.old" \) -print0 2>/dev/null)

    # Combine all targets (safely handle empty arrays)
    CLEANUP_TARGETS=()
    [[ ${#temp_files[@]} -gt 0 ]] && CLEANUP_TARGETS+=("${temp_files[@]}")
    [[ ${#debug_files[@]} -gt 0 ]] && CLEANUP_TARGETS+=("${debug_files[@]}")
    [[ ${#backup_files[@]} -gt 0 ]] && CLEANUP_TARGETS+=("${backup_files[@]}")

    local target_count="${#CLEANUP_TARGETS[@]}"

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Build JSON using jq directly from bash arrays
        # Temporarily disable pipefail for array-to-json conversion
        set +e
        local temp_json="[]"
        [[ ${#temp_files[@]} -gt 0 ]] && temp_json=$(printf '%s\n' "${temp_files[@]}" | jq -R . | jq -s . 2>/dev/null) || temp_json="[]"

        local debug_json="[]"
        [[ ${#debug_files[@]} -gt 0 ]] && debug_json=$(printf '%s\n' "${debug_files[@]}" | jq -R . | jq -s . 2>/dev/null) || debug_json="[]"

        local backup_json="[]"
        [[ ${#backup_files[@]} -gt 0 ]] && backup_json=$(printf '%s\n' "${backup_files[@]}" | jq -R . | jq -s . 2>/dev/null) || backup_json="[]"

        local all_json="[]"
        [[ ${#CLEANUP_TARGETS[@]} -gt 0 ]] && all_json=$(printf '%s\n' "${CLEANUP_TARGETS[@]}" | jq -R . | jq -s . 2>/dev/null) || all_json="[]"
        set -e

        local data
        data=$(jq -n \
            --argjson temp "$temp_json" \
            --argjson debug "$debug_json" \
            --argjson backup "$backup_json" \
            --argjson all "$all_json" \
            --arg count "$target_count" \
            '{ temp_files: $temp, debug_files: $debug, backup_files: $backup, all_targets: $all, total_count: ($count | tonumber) }')

        json_output "success" "identify" "Found $target_count cleanup targets" "$data"
    else
        log_info "identify" "Found $target_count total targets:"
        log_info "identify" "  Temporary files: ${#temp_files[@]}"
        log_info "identify" "  Debug files: ${#debug_files[@]}"
        log_info "identify" "  Backup files: ${#backup_files[@]}"

        if [[ $target_count -gt 0 ]]; then
            log_info "identify" "Targets:"
            for target in "${CLEANUP_TARGETS[@]}"; do
                log_info "identify" "  - $target"
            done
        fi
    fi
}

# ============================================================================
# Section: Analyze Safety
# ============================================================================

analyze_safety() {
    log_info "analyze" "Analyzing cleanup safety"

    if [[ ${#CLEANUP_TARGETS[@]} -eq 0 ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            json_output "success" "analyze" "No targets to analyze" '{"safe_to_delete":true,"warnings":[]}'
        else
            log_info "analyze" "No targets to analyze"
        fi
        return 0
    fi

    local -a warnings=()
    local -a protected_found=()
    local safe_to_delete=true

    # Check for protected files that might have slipped through
    for target in "${CLEANUP_TARGETS[@]}"; do
        if is_protected "$target"; then
            protected_found+=("$target")
            safe_to_delete=false
        fi

        # Check file age - warn about recent files
        if [[ -f "$target" ]]; then
            local age_seconds
            age_seconds=$(($(date +%s) - $(stat -c %Y "$target" 2>/dev/null || stat -f %m "$target" 2>/dev/null || echo 0)))
            if [[ $age_seconds -lt 3600 ]]; then
                warnings+=("Recent file (< 1 hour old): $target")
            fi
        fi
    done

    if [[ ${#protected_found[@]} -gt 0 ]]; then
        warnings+=("Protected files found in targets - filtering them out")
        # Remove protected files from targets
        local -a filtered_targets=()
        for target in "${CLEANUP_TARGETS[@]}"; do
            if ! is_protected "$target"; then
                filtered_targets+=("$target")
            fi
        done
        CLEANUP_TARGETS=("${filtered_targets[@]}")
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Build JSON safely
        local safe_bool="false"
        [[ "$safe_to_delete" == "true" ]] && safe_bool="true"

        # Temporarily disable pipefail for array-to-json conversion
        set +e
        local warnings_json="[]"
        [[ ${#warnings[@]} -gt 0 ]] && warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s . 2>/dev/null) || warnings_json="[]"

        local protected_json="[]"
        [[ ${#protected_found[@]} -gt 0 ]] && protected_json=$(printf '%s\n' "${protected_found[@]}" | jq -R . | jq -s . 2>/dev/null) || protected_json="[]"
        set -e

        local data
        data=$(jq -n \
            --argjson safe "$safe_bool" \
            --argjson warnings "$warnings_json" \
            --argjson protected "$protected_json" \
            --arg target_count "${#CLEANUP_TARGETS[@]}" \
            '{ safe_to_delete: $safe, warnings: $warnings, protected_removed: $protected, remaining_targets: ($target_count | tonumber) }')

        json_output "success" "analyze" "Safety analysis complete" "$data"
    else
        log_info "analyze" "Safety analysis complete"
        log_info "analyze" "Safe to delete: $safe_to_delete"
        log_info "analyze" "Remaining targets: ${#CLEANUP_TARGETS[@]}"

        if [[ ${#warnings[@]} -gt 0 ]]; then
            log_info "analyze" "Warnings:"
            for warning in "${warnings[@]}"; do
                log_info "analyze" "  ⚠️  $warning"
            done
        fi
    fi
}

# ============================================================================
# Section: Cleanup
# ============================================================================

perform_cleanup() {
    log_info "cleanup" "Performing cleanup"

    if [[ ${#CLEANUP_TARGETS[@]} -eq 0 ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            json_output "success" "cleanup" "No files to clean" '{"deleted_count":0,"failed_count":0}'
        else
            log_info "cleanup" "Nothing to clean"
        fi
        return 0
    fi

    local deleted_count=0
    local failed_count=0
    local -a deleted_files=()
    local -a failed_files=()

    for target in "${CLEANUP_TARGETS[@]}"; do
        if [[ -f "$target" ]]; then
            if rm "$target" 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                deleted_files+=("$target")
                log_info "cleanup" "Deleted: $target"
            else
                failed_count=$((failed_count + 1))
                failed_files+=("$target")
                log_error "cleanup" "Failed to delete: $target"
            fi
        elif [[ -d "$target" ]]; then
            if rm -rf "$target" 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                deleted_files+=("$target")
                log_info "cleanup" "Deleted directory: $target"
            else
                failed_count=$((failed_count + 1))
                failed_files+=("$target")
                log_error "cleanup" "Failed to delete directory: $target"
            fi
        fi
    done

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Build JSON safely
        # Temporarily disable pipefail for array-to-json conversion
        set +e
        local deleted_json="[]"
        [[ ${#deleted_files[@]} -gt 0 ]] && deleted_json=$(printf '%s\n' "${deleted_files[@]}" | jq -R . | jq -s . 2>/dev/null) || deleted_json="[]"

        local failed_json="[]"
        [[ ${#failed_files[@]} -gt 0 ]] && failed_json=$(printf '%s\n' "${failed_files[@]}" | jq -R . | jq -s . 2>/dev/null) || failed_json="[]"
        set -e

        local data
        data=$(jq -n \
            --arg deleted "$deleted_count" \
            --arg failed "$failed_count" \
            --argjson deleted_files "$deleted_json" \
            --argjson failed_files "$failed_json" \
            '{ deleted_count: ($deleted | tonumber), failed_count: ($failed | tonumber), deleted_files: $deleted_files, failed_files: $failed_files }')

        if [[ $failed_count -gt 0 ]]; then
            json_output "partial_success" "cleanup" "Cleanup completed with some failures" "$data"
        else
            json_output "success" "cleanup" "Cleanup completed successfully" "$data"
        fi
    else
        log_info "cleanup" "Cleanup complete"
        log_info "cleanup" "  Deleted: $deleted_count files"
        log_info "cleanup" "  Failed: $failed_count files"
    fi
}

# ============================================================================
# Main Workflow
# ============================================================================

run_full_workflow() {
    # Create checkpoint first
    create_checkpoint

    # Identify targets
    identify_targets

    if [[ ${#CLEANUP_TARGETS[@]} -eq 0 ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            json_output "success" "full" "Project is already clean" '{}'
        else
            log_info "full" "Project is already clean"
        fi
        return 0
    fi

    # Analyze safety
    analyze_safety

    # Perform cleanup
    perform_cleanup

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Final summary
        local data
        data=$(jq -n \
            --arg total "${#CLEANUP_TARGETS[@]}" \
            '{
                summary: "Cleanup workflow complete",
                total_targets: $total | tonumber
            }')
        json_output "success" "full" "Project cleanup complete" "$data"
    fi
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_args() {
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
            --identify)
                SECTION="identify"
                shift
                ;;
            --analyze)
                SECTION="analyze"
                shift
                ;;
            --cleanup)
                SECTION="cleanup"
                shift
                ;;
            *)
                if [[ "$OUTPUT_MODE" == "json" ]]; then
                    json_output "error" "args" "Unknown argument: $1" '{}'
                else
                    echo "Error: Unknown argument: $1" >&2
                    echo "Usage: cleanproject.sh [--json|--raw] [--full|--identify|--analyze|--cleanup]" >&2
                fi
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_args "$@"

    case "$SECTION" in
        full)
            run_full_workflow
            ;;
        identify)
            identify_targets
            ;;
        analyze)
            analyze_safety
            ;;
        cleanup)
            perform_cleanup
            ;;
        *)
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                json_output "error" "main" "Unknown section: $SECTION" '{}'
            else
                echo "Error: Unknown section: $SECTION" >&2
            fi
            exit 1
            ;;
    esac
}

main "$@"

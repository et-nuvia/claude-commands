#!/usr/bin/env bash
# prg-sync.sh - Query and update a program (PRG) tracker from a Task ID
#
# A PRG (docs/active/PRG-<DATETIME>-<slug>.md) tracks one initiative across many
# TSKs. Its Workstreams table is the source of truth for cross-task progress.
# This script keeps that table current so it never drifts from reality.
#
# MEMBERSHIP RULE: a TSK belongs to a PRG if and only if its Task ID appears in
# the TSK ID column of some PRG's Workstreams table. If no PRG contains the ID,
# the TSK is not part of a program and every operation is a successful no-op.
# Program bookkeeping never blocks or fails a task operation.
#
# Sections:
#   --check     Is this Task ID in a program? (read-only)
#   --status    Set the workstream Status for this Task ID
#   --bind      Write a Task ID into a workstream row (W#) for the first time
#   --progress  Report done/total for the program owning this Task ID
#
# Examples:
#   prg-sync.sh --json --check --task-id A3F2B9
#   prg-sync.sh --json --status "In progress" --task-id A3F2B9
#   prg-sync.sh --json --status Done --task-id A3F2B9 --stage
#   prg-sync.sh --json --bind --workstream W4 --task-id A3F2B9
#
# Called automatically by: task-start.sh, task-close.sh (via lib/prg-sync.sh).
# Run manually to repair drift or to bind a TSK spawned outside /feature-to-task.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_MODE="human"
OUTPUT_FORMAT=""
SECTION=""
TASK_ID=""
NEW_STATUS=""
WORKSTREAM=""
STAGE=false
FORCE=false

map_status_to_action() {
    case "$1" in
        success)      echo "continue" ;;
        not_member)   echo "continue" ;;
        completed)    echo "review_program_closeout" ;;
        error)        echo "fix_error" ;;
        *)            echo "continue" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/lib/prg-sync.sh"

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)       OUTPUT_MODE="json"; shift ;;
            --toon)       OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw)        OUTPUT_MODE="raw"; shift ;;
            --check)      SECTION="check"; shift ;;
            --progress)   SECTION="progress"; shift ;;
            --bind)       SECTION="bind"; shift ;;
            --status)     SECTION="status"; NEW_STATUS="$2"; shift 2 ;;
            --task-id)    TASK_ID="$2"; shift 2 ;;
            --workstream) WORKSTREAM="$2"; shift 2 ;;
            --stage)      STAGE=true; shift ;;
            --force)      FORCE=true; shift ;;
            -h|--help)    usage ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # Fall back to the active task when no id is given, so the script is usable
    # mid-task without repeating the id.
    if [[ -z "$TASK_ID" ]] && [[ -f ".current-task" ]]; then
        TASK_ID=$(jq -r '.task_id // empty' .current-task 2>/dev/null || echo "")
    fi

    if [[ -z "$TASK_ID" ]]; then
        exit_with_json "error" "No Task ID given and no .current-task to read one from" \
            "Pass --task-id <ID>"
    fi

    local prg
    prg=$(prg_find_for_task "$TASK_ID")

    # ── Not a program member: successful no-op for every section ──
    if [[ -z "$prg" ]] && [[ "$SECTION" != "bind" ]]; then
        exit_with_json "not_member" "Task ${TASK_ID} is not part of any program" \
            "No active PRG in docs/active/ lists ${TASK_ID} in its TSK ID column. Nothing to update." \
            '"task_id": "'"$TASK_ID"'",' \
            '"prg_member": false'
    fi

    case "$SECTION" in
        check)
            local status progress
            status=$(prg_workstream_status "$prg" "$TASK_ID")
            progress=$(prg_progress "$prg")
            exit_with_json "success" "Task ${TASK_ID} belongs to $(basename "$prg")" "" \
                '"task_id": "'"$TASK_ID"'",' \
                '"prg_member": true,' \
                '"prg_path": "'"$prg"'",' \
                '"workstream_status": "'"${status:-unset}"'",' \
                '"progress": "'"$progress"'"'
            ;;

        progress)
            local progress
            progress=$(prg_progress "$prg")
            exit_with_json "success" "Program progress: $progress" "" \
                '"prg_path": "'"$prg"'",' \
                '"progress": "'"$progress"'",' \
                '"all_done": '"$(prg_all_done "$prg" && echo true || echo false)"''
            ;;

        bind)
            if [[ -z "$WORKSTREAM" ]]; then
                exit_with_json "error" "--bind requires --workstream <W#>" "e.g. --workstream W4"
            fi
            # For bind, locate the PRG by workstream rather than by task id,
            # since the id is not in the table yet. Prefer an explicit path via
            # the TSK doc's Program header when the id is unbound.
            local target="$prg"
            if [[ -z "$target" ]]; then
                target=$(_prg_find_by_workstream "$WORKSTREAM")
            fi
            if [[ -z "$target" ]]; then
                exit_with_json "error" "No active PRG contains workstream ${WORKSTREAM}" \
                    "Check docs/active/PRG-*.md"
            fi
            if prg_bind_task "$target" "$WORKSTREAM" "$TASK_ID"; then
                prg_set_status "$target" "$TASK_ID" "TSK created" || true
                [[ "$STAGE" == true ]] && prg_stage_for_commit "$target"
                exit_with_json "success" "Bound ${TASK_ID} to ${WORKSTREAM} in $(basename "$target")" "" \
                    '"prg_path": "'"$target"'",' \
                    '"workstream": "'"$WORKSTREAM"'",' \
                    '"task_id": "'"$TASK_ID"'"'
            else
                exit_with_json "error" "Workstream ${WORKSTREAM} is already bound to a different Task ID" \
                    "Inspect $target and resolve manually"
            fi
            ;;

        status)
            if [[ -z "$NEW_STATUS" ]]; then
                exit_with_json "error" "--status requires a value" \
                    "One of: Not started, TSK created, In progress, In review, Merged to dev, On staging, In production, Done, Blocked, Dropped"
            fi

            local before after progress
            before=$(prg_workstream_status "$prg" "$TASK_ID")
            if [[ "$FORCE" == true ]]; then
                prg_set_status "$prg" "$TASK_ID" "$NEW_STATUS" --force || true
            else
                prg_set_status "$prg" "$TASK_ID" "$NEW_STATUS" || true
            fi
            after=$(prg_workstream_status "$prg" "$TASK_ID")

            if [[ "$before" != "$after" ]]; then
                prg_append_status_log "$prg" "${TASK_ID}: ${before:-unset} → ${after}" || true
            fi

            progress=$(prg_progress "$prg")

            # Auto-complete the program when this was the last workstream.
            local moved=""
            if _prg_is_terminal "$after" && prg_all_done "$prg"; then
                moved=$(prg_complete_and_move "$prg" 2>/dev/null || echo "")
            fi

            if [[ -n "$moved" ]]; then
                [[ "$STAGE" == true ]] && prg_stage_for_commit "$moved"
                exit_with_json "completed" "All workstreams terminal — program moved to completed/" \
                    "Closeout checklist items in the PRG are NOT auto-verified. Confirm metrics were re-measured, corrections applied, and lessons promoted." \
                    '"prg_path": "'"$moved"'",' \
                    '"prg_completed": true,' \
                    '"workstream_status_before": "'"${before:-unset}"'",' \
                    '"workstream_status_after": "'"${after:-unset}"'",' \
                    '"progress": "'"$progress"'",' \
                    '"closeout_checklist": "unverified"'
            else
                [[ "$STAGE" == true ]] && prg_stage_for_commit "$prg"
                exit_with_json "success" "Workstream status: ${before:-unset} → ${after:-unset}" "" \
                    '"prg_path": "'"$prg"'",' \
                    '"prg_completed": false,' \
                    '"workstream_status_before": "'"${before:-unset}"'",' \
                    '"workstream_status_after": "'"${after:-unset}"'",' \
                    '"progress": "'"$progress"'"'
            fi
            ;;

        *)
            exit_with_json "error" "No section given" \
                "Use one of --check, --status <value>, --bind --workstream <W#>, --progress"
            ;;
    esac
}

# Locate the active PRG containing a given workstream id (used only by --bind,
# where the Task ID is not yet in the table).
_prg_find_by_workstream() {
    local wnum="$1"
    local docs_dir active_dir prg
    docs_dir=$(find_docs_dir 2>/dev/null || echo "docs")
    active_dir="${docs_dir}/active"
    [[ -d "$active_dir" ]] || return 0

    while IFS= read -r prg; do
        [[ -z "$prg" ]] && continue
        if grep -qE "^\|[[:space:]]*${wnum}[[:space:]]*\|" "$prg" 2>/dev/null; then
            echo "$prg"
            return 0
        fi
    done < <(find "$active_dir" -maxdepth 1 -name "PRG-*.md" 2>/dev/null | sort)
    return 0
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# rotate-secret.sh - Manage secret rotation with automated reminders and guided workflows
# Usage:
#   rotate-secret.sh --json --status
#   rotate-secret.sh --json --rotate <bucket>
#   rotate-secret.sh --json --schedule
#   rotate-secret.sh --json --setup-reminders
#   rotate-secret.sh --raw --status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_MODE="json"
ROTATION_HISTORY="${HOME}/.claude/rotation-history.json"

# Custom status-to-action mapping (must be defined before sourcing output-framework.sh)
map_status_to_action() {
    case "$1" in
        success)       echo "display_summary" ;;
        intervention)  echo "guide_rotation" ;;
        error)         echo "fix_error" ;;
        *)             echo "display_summary" ;;
    esac
}

# shellcheck source=lib/yaml.sh
source "${SCRIPT_DIR}/lib/yaml.sh" || {
    echo "{\"status\":\"error\",\"message\":\"Failed to load yaml.sh\"}" >&2
    exit 1
}

# shellcheck source=lib/output-framework.sh
source "${SCRIPT_DIR}/lib/output-framework.sh" || {
    echo "{\"status\":\"error\",\"message\":\"Failed to load output-framework.sh\"}" >&2
    exit 1
}

json_response() {
    local status="$1" section="$2" message="$3"; shift 3
    local next_action
    next_action=$(map_status_to_action "$status")
    local extra=""
    while [[ $# -gt 0 ]]; do extra="${extra}, $1"; shift; done
    log_json "{\"status\":\"${status}\",\"section\":\"${section}\",\"message\":\"${message}\",\"next_action\":\"${next_action}\",\"timestamp\":\"$(date -Iseconds)\"${extra}}"
}

load_config() {
    [[ ! -f "PROJECT.yaml" ]] && { json_response "error" "config" "PROJECT.yaml not found" "\"details\": \"Run /project-config init\""; exit 1; }
    SECRETS_BACKEND=$(yaml_get '.secrets.backend' PROJECT.yaml)
    ROTATION_ENABLED=$(yaml_get_default '.secrets.rotation.enabled' 'false' PROJECT.yaml)
    [[ "$ROTATION_ENABLED" != "true" ]] && { json_response "error" "config" "Secret rotation not enabled" "\"details\": \"Set secrets.rotation.enabled: true in PROJECT.yaml\""; exit 1; }
}

get_last_rotation() {
    local bucket="$1"
    [[ ! -f "$ROTATION_HISTORY" ]] && { echo "0"; return; }
    local project_dir; project_dir=$(pwd)
    jq -r --arg proj "$project_dir" --arg bucket "$bucket" '.[$proj][$bucket] // 0' "$ROTATION_HISTORY" 2>/dev/null || echo "0"
}

check_rotation_status() {
    load_config
    local due=() approaching=() uptodate=()
    local schedule_count; schedule_count=$(yaml_get '.secrets.rotation.schedules | length' PROJECT.yaml)
    for i in $(seq 0 $((schedule_count - 1))); do
        local bucket; bucket=$(yaml_get ".secrets.rotation.schedules | keys | .[$i]" PROJECT.yaml)
        local frequency; frequency=$(yaml_get ".secrets.rotation.schedules.${bucket}.frequency_days" PROJECT.yaml)
        local warning_days; warning_days=$(yaml_get ".secrets.rotation.schedules.${bucket}.notification_days_before" PROJECT.yaml)
        local last_rotation; last_rotation=$(get_last_rotation "$bucket")
        local days_since=$(( ($(date +%s) - last_rotation) / 86400 ))
        local days_until_due=$(( frequency - days_since ))
        if [[ $days_until_due -lt 0 ]]; then
            due+=("{\"bucket\":\"$bucket\",\"days_overdue\":$((-days_until_due)),\"frequency_days\":$frequency}")
        elif [[ $days_until_due -le $warning_days ]]; then
            approaching+=("{\"bucket\":\"$bucket\",\"days_until_due\":$days_until_due,\"frequency_days\":$frequency}")
        else
            uptodate+=("{\"bucket\":\"$bucket\",\"days_since\":$days_since,\"frequency_days\":$frequency}")
        fi
    done
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Rotation Status"; echo "═══════════════════════════════════════════"
        [[ ${#due[@]} -gt 0 ]] && { echo "Due (overdue):"; printf '%s\n' "${due[@]}" | jq -r '"  OVERDUE: \(.bucket) (\(.days_overdue) days overdue)"'; }
        [[ ${#approaching[@]} -gt 0 ]] && { echo "Approaching:"; printf '%s\n' "${approaching[@]}" | jq -r '"  WARNING: \(.bucket) (due in \(.days_until_due) days)"'; }
        [[ ${#uptodate[@]} -gt 0 ]] && { echo "Up to date:"; printf '%s\n' "${uptodate[@]}" | jq -r '"  OK: \(.bucket) (\(.days_since) days ago)"'; }
    else
        local due_json; due_json=$(printf '%s\n' "${due[@]}" | jq -s '.' 2>/dev/null || echo "[]")
        local approaching_json; approaching_json=$(printf '%s\n' "${approaching[@]}" | jq -s '.' 2>/dev/null || echo "[]")
        local uptodate_json; uptodate_json=$(printf '%s\n' "${uptodate[@]}" | jq -s '.' 2>/dev/null || echo "[]")
        json_response "success" "status" "Rotation status retrieved" \
            "\"due\": $due_json" "\"approaching\": $approaching_json" "\"up_to_date\": $uptodate_json"
    fi
}

show_schedule() {
    load_config
    local schedules=()
    local schedule_count; schedule_count=$(yaml_get '.secrets.rotation.schedules | length' PROJECT.yaml)
    for i in $(seq 0 $((schedule_count - 1))); do
        local bucket; bucket=$(yaml_get ".secrets.rotation.schedules | keys | .[$i]" PROJECT.yaml)
        local frequency; frequency=$(yaml_get ".secrets.rotation.schedules.${bucket}.frequency_days" PROJECT.yaml)
        local warning; warning=$(yaml_get ".secrets.rotation.schedules.${bucket}.notification_days_before" PROJECT.yaml)
        local auto_rotate; auto_rotate=$(yaml_get ".secrets.rotation.schedules.${bucket}.auto_rotate" PROJECT.yaml)
        local strategy; strategy=$(yaml_get ".secrets.rotation.schedules.${bucket}.strategy" PROJECT.yaml)
        local last_rotation; last_rotation=$(get_last_rotation "$bucket")
        local last_rotated_date="Never" next_due_date="N/A"
        [[ $last_rotation -gt 0 ]] && { last_rotated_date=$(date -d "@$last_rotation" +%Y-%m-%d); next_due_date=$(date -d "@$((last_rotation + frequency * 86400))" +%Y-%m-%d); }
        schedules+=("{\"bucket\":\"$bucket\",\"frequency_days\":$frequency,\"warning_days\":$warning,\"auto_rotate\":$auto_rotate,\"strategy\":\"$strategy\",\"last_rotated\":\"$last_rotated_date\",\"next_due\":\"$next_due_date\"}")
    done
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "Rotation Schedule"; echo "═══════════════════════════════════════════"
        printf '%s\n' "${schedules[@]}" | jq -r '"\(.bucket): frequency=\(.frequency_days)d, strategy=\(.strategy), last=\(.last_rotated), next=\(.next_due)"'
    else
        local schedules_json; schedules_json=$(printf '%s\n' "${schedules[@]}" | jq -s '.')
        json_response "success" "schedule" "Rotation schedule retrieved" "\"schedules\": $schedules_json"
    fi
}

main() {
    local action="" bucket=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --status) action="status"; shift ;;
            --schedule) action="schedule"; shift ;;
            --rotate) action="rotate"; bucket="$2"; shift 2 ;;
            --setup-reminders) action="setup-reminders"; shift ;;
            *) json_response "error" "args" "Unknown argument: $1"; exit 1 ;;
        esac
    done
    case "$action" in
        status) check_rotation_status ;;
        schedule) show_schedule ;;
        rotate) json_response "intervention" "rotate" "Ready to rotate secret: $bucket" "\"bucket\": \"$bucket\"" "\"next_steps\": [\"Guide through rotation workflow based on strategy\"]" ;;
        setup-reminders) json_response "intervention" "setup" "Ready to setup rotation reminders" "\"next_steps\": [\"Create appropriate reminder mechanism (cron/CI)\"]" ;;
        *) json_response "error" "args" "No action specified" "\"details\": \"Use --status, --schedule, --rotate, or --setup-reminders\""; exit 1 ;;
    esac
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# project-config.sh - Manage PROJECT.yaml configuration
# Usage: project-config.sh [--json|--raw] [init|show|validate|update FIELD VAL]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"
PROJECT_ROOT="${PWD}"
PROJECT_FILE="${PROJECT_ROOT}/PROJECT.yaml"
TEMPLATE_FILE="${HOME}/.claude/templates/PROJECT.yaml"
VALIDATOR="${HOME}/.claude/scripts/validate-project.py"
OUTPUT_MODE="json"
COMMAND=""
ARGS=()

SECTION="project-config"
map_status_to_action() {
    case "$1" in
        success)           echo "display_summary" ;;
        validation_failed) echo "fix_validation_errors" ;;
        *)                 _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --help|-h) echo "Usage: $0 [--json|--raw] [init|show|validate|update FIELD VAL]"; exit 0 ;;
        init|show|validate|update) COMMAND="$1"; shift; ARGS=("$@"); break ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

json_output() {
    local status="$1" message="$2" details="${3:-null}"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local next_action
        next_action=$(map_status_to_action "$status")
        local json="{\"status\":\"$status\",\"message\":\"$message\",\"next_action\":\"$next_action\""
        [[ "$details" != "null" ]] && json="$json,\"details\":$details"
        json="$json,\"section\":\"${SECTION:-}\",\"timestamp\":\"$(date -Iseconds)\"}"
        log_json "$json"
    else
        case "$status" in
            success) log "${GREEN}✓${NC} $message" ;;
            error) log "${RED}✗${NC} $message" ;;
            *) log "$message" ;;
        esac
        [[ "$details" != "null" ]] && echo "$details" | jq -r '.' 2>/dev/null || true
    fi
}

detect_project_values() {
    local name; name="$(basename "$PROJECT_ROOT")"
    [[ -f "package.json" ]] && { local pkg_name; pkg_name=$(jq -r '.name // ""' package.json 2>/dev/null); [[ -n "$pkg_name" ]] && name="$pkg_name"; }
    [[ -f "pyproject.toml" ]] && { local py_name; py_name=$(grep -m1 '^name = ' pyproject.toml 2>/dev/null | cut -d'"' -f2 || echo ""); [[ -n "$py_name" ]] && name="$py_name"; }
    local lang_array=()
    [[ -f "package.json" ]] && lang_array+=("\"typescript\"")
    [[ -f "pyproject.toml" || -f "requirements.txt" ]] && lang_array+=("\"python\"")
    [[ -f "go.mod" ]] && lang_array+=("\"go\"")
    [[ -f "Cargo.toml" ]] && lang_array+=("\"rust\"")
    local languages="[$(IFS=,; echo "${lang_array[*]}")]"
    local services="[]"
    [[ -f "docker-compose.yml" ]] && { local svc_array=(); while IFS= read -r svc; do [[ -n "$svc" ]] && svc_array+=("\"$svc\""); done < <(yaml_get_array '.services | keys' docker-compose.yml); [[ ${#svc_array[@]} -gt 0 ]] && services="[$(IFS=,; echo "${svc_array[*]}")]"; }
    local platform="gitlab" backend="infisical"
    git remote get-url origin 2>/dev/null | grep -q "github\.com" && platform="github"
    [[ "$(uname -s)" == "Darwin" ]] && backend="aws"
    echo "{\"name\":\"$name\",\"languages\":$languages,\"services\":$services,\"platform\":\"$platform\",\"backend\":\"$backend\"}"
}

init_project() {
    [[ -f "$PROJECT_FILE" ]] && { json_output "error" "PROJECT.yaml already exists" "null"; return 1; }
    [[ ! -f "$TEMPLATE_FILE" ]] && { json_output "error" "Template not found: $TEMPLATE_FILE" "null"; return 1; }
    local detected; detected=$(detect_project_values)
    cp "$TEMPLATE_FILE" "$PROJECT_FILE"
    json_output "success" "PROJECT.yaml initialized" "{\"created\":\"$PROJECT_FILE\",\"detected\":$detected,\"next_steps\":[\"Review and update PROJECT.yaml\",\"Run: $0 validate\"]}"
}

show_project() {
    [[ ! -f "$PROJECT_FILE" ]] && { json_output "error" "PROJECT.yaml not found" "{\"action\":\"Run: $0 init\"}"; return 1; }
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Convert full YAML to JSON (yaml_get can't do format conversion, so use yq directly via _detect_yq_variant)
        local yaml_json
        _detect_yq_variant
        if [[ "$_YQ_VARIANT" == "python" ]]; then
            yaml_json=$(yq -r '.' "$PROJECT_FILE" 2>/dev/null || echo "{}")
        else
            yaml_json=$(yq eval -o=json "$PROJECT_FILE" 2>/dev/null || echo "{}")
        fi
        echo "{\"status\":\"success\",\"message\":\"Current PROJECT.yaml configuration\",\"next_action\":\"display_summary\",\"config\":$yaml_json,\"timestamp\":\"$(date -Iseconds)\"}"
    else echo -e "${BLUE}Current PROJECT.yaml:${NC}"; echo ""; cat "$PROJECT_FILE"; fi
}

validate_project() {
    [[ ! -f "$PROJECT_FILE" ]] && { json_output "error" "PROJECT.yaml not found" "{\"action\":\"Run: $0 init\"}"; return 1; }
    [[ ! -f "$VALIDATOR" ]] && { json_output "error" "Validator not found: $VALIDATOR" "null"; return 1; }
    local result rc=0
    result=$(uv run --with pyyaml --with 'jsonschema[format]' --quiet --python 3.12 "$VALIDATOR" --json 2>&1) || rc=$?
    case "$rc" in
        0)
            json_output "success" "PROJECT.yaml is valid" "$(echo "$result" | jq '{summary, warnings: (.issues | map(select(.severity=="warning")))}')"
            ;;
        1)
            json_output "validation_failed" "PROJECT.yaml validation failed" "$result"
            return 1
            ;;
        *)
            json_output "error" "Validator crashed (exit $rc)" "$(echo "$result" | jq -Rs .)"
            return 1
            ;;
    esac
}

update_field() {
    local field="$1" value="$2"
    [[ ! -f "$PROJECT_FILE" ]] && { json_output "error" "PROJECT.yaml not found" "{\"action\":\"Run: $0 init\"}"; return 1; }
    if yq eval ".$field = \"$value\"" -i "$PROJECT_FILE" 2>/dev/null; then
        json_output "success" "Field updated" "{\"field\":\"$field\",\"value\":\"$value\",\"file\":\"$PROJECT_FILE\"}"
    else
        json_output "error" "Failed to update field: $field" "null"; return 1
    fi
}

case "${COMMAND:-show}" in
    init) init_project ;;
    show) show_project ;;
    validate) validate_project ;;
    update)
        [[ ${#ARGS[@]} -lt 2 ]] && { echo "Error: update requires FIELD and VALUE" >&2; exit 1; }
        update_field "${ARGS[0]}" "${ARGS[1]}"
        ;;
    *) echo "Unknown command: $COMMAND" >&2; exit 1 ;;
esac

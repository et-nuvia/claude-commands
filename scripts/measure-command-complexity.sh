#!/usr/bin/env bash
set -euo pipefail

# measure-command-complexity.sh - Measure complexity of command/script pairs
#
# Usage:
#   measure-command-complexity.sh [--csv] [--top N] [command-name]
#
# Output:
#   Default: Human-readable summary
#   --csv: CSV format for baseline/comparison
#   --top N: Show only top N most complex (default: all)
#   command-name: Measure single command only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="${SCRIPT_DIR}/../commands"
SCRIPTS_DIR="${SCRIPT_DIR}"

OUTPUT_MODE="table"
TOP_N=0
SINGLE_COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --csv) OUTPUT_MODE="csv"; shift ;;
        --top) TOP_N="$2"; shift 2 ;;
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        *) SINGLE_COMMAND="$1"; shift ;;
    esac
done

# Measure a single command file
measure_command() {
    local name="$1"
    local cmd_file="${COMMANDS_DIR}/${name}.md"
    local script_file="${SCRIPTS_DIR}/${name}.sh"

    local cmd_lines=0 cmd_bash_blocks=0 cmd_jq_calls=0 cmd_case_stmts=0
    local script_lines=0 script_has_next_action=0 script_has_project_yaml=0 script_has_verbose=0

    # Command file metrics
    if [[ -f "$cmd_file" ]]; then
        cmd_lines=$(wc -l < "$cmd_file" | tr -d ' ')
        cmd_bash_blocks=$(grep -c '```bash' "$cmd_file" 2>/dev/null || true)
        cmd_jq_calls=$(grep -c 'jq ' "$cmd_file" 2>/dev/null || true)
        cmd_case_stmts=$(grep -cE 'case .* in|esac' "$cmd_file" 2>/dev/null || true)
    fi

    # Script file metrics
    if [[ -f "$script_file" ]]; then
        script_lines=$(wc -l < "$script_file" | tr -d ' ')
        script_has_next_action=$(grep -c 'next_action' "$script_file" 2>/dev/null || true)
        script_has_project_yaml=$(grep -cE 'PROJECT\.yaml|project-config' "$script_file" 2>/dev/null || true)
        script_has_verbose=$(grep -cE '\-v\b|--verbose|VERBOSITY' "$script_file" 2>/dev/null || true)
    fi

    # Ensure numeric values
    cmd_lines=${cmd_lines:-0}; cmd_bash_blocks=${cmd_bash_blocks:-0}
    cmd_jq_calls=${cmd_jq_calls:-0}; cmd_case_stmts=${cmd_case_stmts:-0}
    script_lines=${script_lines:-0}; script_has_next_action=${script_has_next_action:-0}
    script_has_project_yaml=${script_has_project_yaml:-0}; script_has_verbose=${script_has_verbose:-0}

    # Complexity score: weighted sum
    # High command lines = bad, high bash blocks = bad, jq in commands = bad
    local complexity=$(( cmd_lines + (cmd_bash_blocks * 20) + (cmd_jq_calls * 10) + (cmd_case_stmts * 15) ))

    echo "${name}|${cmd_lines}|${cmd_bash_blocks}|${cmd_jq_calls}|${cmd_case_stmts}|${script_lines}|${script_has_next_action}|${script_has_project_yaml}|${script_has_verbose}|${complexity}"
}

# Collect all measurements
collect_measurements() {
    local results=()

    if [[ -n "$SINGLE_COMMAND" ]]; then
        results+=("$(measure_command "$SINGLE_COMMAND")")
    else
        # Find all command files
        for cmd_file in "${COMMANDS_DIR}"/*.md; do
            [[ ! -f "$cmd_file" ]] && continue
            local name=$(basename "$cmd_file" .md)
            results+=("$(measure_command "$name")")
        done
    fi

    # Sort by complexity (last field) descending
    printf '%s\n' "${results[@]}" | sort -t'|' -k10 -rn
}

# Output as CSV
output_csv() {
    echo "command,cmd_lines,bash_blocks,jq_calls,case_stmts,script_lines,has_next_action,has_project_yaml,has_verbose,complexity_score"
    local count=0
    while IFS='|' read -r name cmd_lines bash_blocks jq_calls case_stmts script_lines next_action project_yaml verbose complexity; do
        echo "${name},${cmd_lines},${bash_blocks},${jq_calls},${case_stmts},${script_lines},${next_action},${project_yaml},${verbose},${complexity}"
        count=$((count + 1))
        [[ $TOP_N -gt 0 ]] && [[ $count -ge $TOP_N ]] && break
    done
}

# Output as table
output_table() {
    local total_commands=0 total_cmd_lines=0 total_bash_blocks=0 total_jq=0

    printf "%-30s %6s %6s %4s %5s %7s %4s\n" "COMMAND" "LINES" "BASH" "JQ" "CASE" "SCRIPT" "SCORE"
    printf "%-30s %6s %6s %4s %5s %7s %4s\n" "-------" "-----" "----" "--" "----" "------" "-----"

    local count=0
    while IFS='|' read -r name cmd_lines bash_blocks jq_calls case_stmts script_lines next_action project_yaml verbose complexity; do
        printf "%-30s %6s %6s %4s %5s %7s %4s\n" "$name" "$cmd_lines" "$bash_blocks" "$jq_calls" "$case_stmts" "$script_lines" "$complexity"
        total_commands=$((total_commands + 1))
        total_cmd_lines=$((total_cmd_lines + cmd_lines))
        total_bash_blocks=$((total_bash_blocks + bash_blocks))
        total_jq=$((total_jq + jq_calls))
        count=$((count + 1))
        [[ $TOP_N -gt 0 ]] && [[ $count -ge $TOP_N ]] && break
    done

    echo ""
    echo "Summary:"
    echo "  Commands measured: $total_commands"
    if [[ $total_commands -gt 0 ]]; then
        echo "  Avg command lines: $((total_cmd_lines / total_commands))"
        echo "  Avg bash blocks:   $((total_bash_blocks / total_commands))"
        echo "  Total jq calls:    $total_jq"
    fi
}

# Output as JSON
output_json() {
    echo "["
    local first=true
    local count=0
    while IFS='|' read -r name cmd_lines bash_blocks jq_calls case_stmts script_lines next_action project_yaml verbose complexity; do
        $first && first=false || echo ","
        cat <<EOF
  {"command":"$name","cmd_lines":$cmd_lines,"bash_blocks":$bash_blocks,"jq_calls":$jq_calls,"case_stmts":$case_stmts,"script_lines":$script_lines,"has_next_action":$([ "$next_action" -gt 0 ] && echo true || echo false),"has_project_yaml":$([ "$project_yaml" -gt 0 ] && echo true || echo false),"has_verbose":$([ "$verbose" -gt 0 ] && echo true || echo false),"complexity":$complexity}
EOF
        count=$((count + 1))
        [[ $TOP_N -gt 0 ]] && [[ $count -ge $TOP_N ]] && break
    done
    echo "]"
}

# Main
measurements=$(collect_measurements)

case "$OUTPUT_MODE" in
    csv)   echo "$measurements" | output_csv ;;
    table) echo "$measurements" | output_table ;;
    json)  echo "$measurements" | output_json ;;
esac

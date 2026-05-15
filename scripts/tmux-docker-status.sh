#!/usr/bin/env bash
set -euo pipefail

# tmux-docker-status.sh — Flicker-free docker status for tmux pane
# Uses docker-ps.sh (dps) filtered to the current project's compose containers.
# Designed to run BELOW a tab bar — does NOT clear or move to row 1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DPS="${SCRIPT_DIR}/docker-ps.sh"

PROJECT_DIR="${1:-.}"
cd "${PROJECT_DIR}"

PROJECT_NAME="$(basename "${PROJECT_DIR}")"

# Hide cursor
printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

get_rows() { tput lines 2>/dev/null || echo 24; }

# Determine compose project name once (avoid calling docker compose config in the loop)
# Docker compose default: lowercase dir name, strip non-alphanumeric except dash/underscore
compose_project=$(echo "${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')

# Check for compose file once
compose_file=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$f" ]; then compose_file="$f"; break; fi
done

# Save cursor position on first run (below the tab bar)
printf '\033[s'

while true; do
    buf=""
    buf+="\033[1;35m  Docker Containers\033[0m  \033[90m(${PROJECT_NAME})\033[0m\n"
    buf+="\033[90m─────────────────────────────────────────\033[0m\n"

    if [ -n "$compose_file" ]; then
        # Use dps filtered to this project's containers
        ps_output=$("${DPS}" --filter "label=com.docker.compose.project=${compose_project}" 2>/dev/null || true)

        if [ -z "$ps_output" ] || [ "$(echo "$ps_output" | wc -l)" -le 1 ]; then
            buf+="\033[90m  No running containers.\033[0m\n"
            buf+="\033[90m  Run: docker compose up -d\033[0m\n"
        else
            while IFS= read -r line; do
                if echo "$line" | grep -qi "CONTAINER ID"; then
                    buf+="\033[1m  ${line}\033[0m\n"
                elif echo "$line" | grep -qi "up\|running\|healthy"; then
                    buf+="\033[32m  ${line}\033[0m\n"
                elif echo "$line" | grep -qi "exit\|dead\|unhealthy"; then
                    buf+="\033[31m  ${line}\033[0m\n"
                elif echo "$line" | grep -qi "starting\|restarting\|created"; then
                    buf+="\033[33m  ${line}\033[0m\n"
                else
                    buf+="  ${line}\n"
                fi
            done <<< "$ps_output"
        fi
    else
        buf+="\033[90m  No compose file in this project.\033[0m\n"
    fi

    # Pad to clear stale lines
    rows=$(get_rows)
    line_count=$(echo -e "$buf" | wc -l)
    padding=$((rows - line_count - 3))  # Account for tab bar above
    for ((i = 0; i < padding && i < 20; i++)); do
        buf+="\033[K\n"
    done

    # Restore to saved cursor position (just below tab bar) and draw
    printf '\033[u'
    printf '%b' "$buf"

    sleep 5
done

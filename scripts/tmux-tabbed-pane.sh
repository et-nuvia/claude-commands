#!/usr/bin/env bash

# tmux-tabbed-pane.sh — Tabbed view: Console | Docker
# Defaults to Docker tab. Switch with number keys.
#
# Controls:
#   1 — Console (interactive shell, exit/Ctrl-D returns to Docker)
#   2 — Docker (project containers via dps, auto-refresh)
#   q — quit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DPS="${SCRIPT_DIR}/docker-ps.sh"
PROJECT_DIR="${1:-.}"
cd "${PROJECT_DIR}" || exit 1

PROJECT_NAME="$(basename "${PROJECT_DIR}")"
COMPOSE_PROJECT=$(echo "${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$f" ]; then COMPOSE_FILE="$f"; break; fi
done

run_console() {
    clear
    echo -e "\033[1;46;30m 1: Console \033[0m \033[90m 2: Docker \033[0m"
    echo -e "\033[90m  exit or Ctrl-D to return to Docker tab\033[0m"
    echo ""
    env PS1=$'\033[36m[claude]\033[0m \w \$ ' bash --norc --noprofile 2>/dev/null || true
}

docker_frame() {
    echo -e "\033[90m 1: Console \033[0m \033[1;45;30m 2: Docker \033[0m \033[90m q: quit\033[0m"
    echo -e "\033[1;35m  Containers\033[0m  \033[90m(${PROJECT_NAME})\033[0m"

    if [ -z "$COMPOSE_FILE" ]; then
        echo -e "\033[90m  No compose file in this project.\033[0m"
        return
    fi

    local ps_output
    ps_output=$("${DPS}" --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null) || true

    if [ -z "$ps_output" ] || [ "$(echo "$ps_output" | wc -l)" -le 1 ]; then
        echo -e "\033[90m  No running containers.\033[0m"
        echo -e "\033[90m  Run: docker compose up -d\033[0m"
    else
        while IFS= read -r line; do
            if echo "$line" | grep -qi "CONTAINER ID"; then
                echo -e "\033[1m  ${line}\033[0m"
            elif echo "$line" | grep -qi "up\|running\|healthy"; then
                echo -e "\033[32m  ${line}\033[0m"
            elif echo "$line" | grep -qi "exit\|dead\|unhealthy"; then
                echo -e "\033[31m  ${line}\033[0m"
            elif echo "$line" | grep -qi "starting\|restarting\|created"; then
                echo -e "\033[33m  ${line}\033[0m"
            else
                echo "  ${line}"
            fi
        done <<< "$ps_output"
    fi
}

run_docker() {
    while true; do
        # Render frame to a temp file, then display in one shot
        local tmpf
        tmpf=$(mktemp)
        docker_frame > "$tmpf" 2>/dev/null

        # Clear and display
        tput clear 2>/dev/null || clear
        cat "$tmpf"
        rm -f "$tmpf"

        # Wait up to 5 seconds, checking for keypress every 0.5s
        local i=0
        while [ "$i" -lt 10 ]; do
            if IFS= read -rsn1 -t 0.5 key 2>/dev/null; then
                case "$key" in
                    1) NEXT_TAB="console"; return ;;
                    q) NEXT_TAB="quit"; return ;;
                esac
            fi
            i=$((i + 1))
        done
    done
}

# Main loop — default to docker
NEXT_TAB="docker"

while true; do
    case "$NEXT_TAB" in
        console)
            run_console
            NEXT_TAB="docker"
            ;;
        docker)
            run_docker
            ;;
        quit)
            break
            ;;
    esac
done

clear
echo -e "\033[90m  Tabbed pane closed.\033[0m"

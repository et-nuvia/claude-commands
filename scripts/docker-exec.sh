#!/usr/bin/env bash
# docker-exec.sh - Resolve and exec into a Docker Compose service container
#
# Resolves the running container for a service by checking (in order):
#   1. Explicit container_name from docker-compose.yml
#   2. `docker compose ps` lookup for the service
#   3. Auto-generated name pattern: <project>-<service>-<N>
#
# If the container is not running, starts it automatically.
#
# Usage:
#   ~/.claude/scripts/docker-exec.sh -s <service> [-d <project_dir>] [-- command args...]
#   ~/.claude/scripts/docker-exec.sh -s api -- uv run pytest
#   ~/.claude/scripts/docker-exec.sh -s web -- npx vitest run
#
# See: ~/.claude/references/docker-exec.md

set -euo pipefail

SERVICE=""
PROJECT_DIR=""

usage() {
    echo "Usage: $0 -s <service> [-d <project_dir>] [-- command args...]" >&2
    echo "" >&2
    echo "  -s, --service    Docker Compose service name (required)" >&2
    echo "  -d, --dir        Project directory containing docker-compose.yml" >&2
    echo "                   (default: current working directory)" >&2
    exit 1
}

# Parse flags (everything before --)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--service) SERVICE="$2"; shift 2 ;;
        -d|--dir) PROJECT_DIR="$2"; shift 2 ;;
        --) shift; break ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "$SERVICE" ]]; then
    echo "Error: -s <service> is required" >&2
    usage
fi

# Remaining args are the command to exec
EXEC_CMD=("$@")
if [[ ${#EXEC_CMD[@]} -eq 0 ]]; then
    echo "Error: no command specified after --" >&2
    usage
fi

# Resolve project directory
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Error: docker-compose.yml not found at ${COMPOSE_FILE}" >&2
    exit 1
fi

#------------------------------------------------------------------------------
# Extract explicit container_name from compose file for a service
#------------------------------------------------------------------------------
find_explicit_name() {
    # Parse YAML: find the service block, extract container_name value
    awk -v svc="  ${SERVICE}:" '
        $0 ~ "^"svc"$" || $0 ~ "^"svc" " {found=1; next}
        found && /^  [^ ]/ {exit}
        found && /^\s+container_name:/ {
            gsub(/.*container_name:\s*/, "")
            gsub(/["'"'"' ]/, "")
            print
            exit
        }
    ' "$COMPOSE_FILE"
}

#------------------------------------------------------------------------------
# Check if a container is running by name
#------------------------------------------------------------------------------
is_running() {
    local name="$1"
    docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null | grep -q "true"
}

#------------------------------------------------------------------------------
# Resolve container - try all strategies, return container name or fail
#------------------------------------------------------------------------------
resolve_container() {
    # Strategy 1: Explicit container_name from compose file
    local explicit
    explicit=$(find_explicit_name)
    if [[ -n "$explicit" ]] && is_running "$explicit"; then
        echo "$explicit"
        return 0
    fi

    # Strategy 2: Ask docker compose directly
    local compose_name
    compose_name=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$SERVICE" 2>/dev/null | head -1)
    if [[ -n "$compose_name" ]] && is_running "$compose_name"; then
        echo "$compose_name"
        return 0
    fi

    # Strategy 3: Try auto-generated pattern <project>-<service>-N
    local project_name
    project_name=$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    for n in 1 2 3; do
        local guess="${project_name}-${SERVICE}-${n}"
        if is_running "$guess"; then
            echo "$guess"
            return 0
        fi
    done

    return 1
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

CONTAINER=""

if CONTAINER=$(resolve_container); then
    docker exec "$CONTAINER" "${EXEC_CMD[@]}"
else
    echo "Service '${SERVICE}' not running, starting..." >&2
    docker compose -f "$COMPOSE_FILE" up -d "$SERVICE" >&2

    # Wait for the container to be running (up to 30s)
    for _ in $(seq 1 30); do
        if CONTAINER=$(resolve_container); then
            break
        fi
        sleep 1
    done

    if [[ -z "$CONTAINER" ]]; then
        echo "Error: could not resolve container for service '${SERVICE}' after starting" >&2
        exit 1
    fi

    docker exec "$CONTAINER" "${EXEC_CMD[@]}"
fi

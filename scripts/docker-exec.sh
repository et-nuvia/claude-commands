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
BASE_COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

if [[ ! -f "$BASE_COMPOSE_FILE" ]]; then
    echo "Error: docker-compose.yml not found at ${BASE_COMPOSE_FILE}" >&2
    exit 1
fi

# Build the compose -f arg list. Passing -f explicitly DISABLES docker compose's
# automatic merge of docker-compose.override.yml, so re-add it ourselves when
# present — otherwise dev-only override settings (port maps, secret file paths,
# bind mounts) are silently dropped and `up -d` can fail or start the wrong config.
#
# An INHERITED COMPOSE_FILE (colon-separated) wins: projects that give each git
# worktree its own stack export it to add a per-worktree layer, and rebuilding the
# list from PROJECT_DIR here would silently drop that layer and target the wrong
# stack.
COMPOSE_ARGS=()
if [[ -n "${COMPOSE_FILE:-}" ]]; then
    IFS="${COMPOSE_PATH_SEPARATOR:-:}" read -r -a _inherited <<< "$COMPOSE_FILE"
    for f in "${_inherited[@]}"; do
        [[ -n "$f" ]] && COMPOSE_ARGS+=(-f "$f")
    done
fi
if [[ ${#COMPOSE_ARGS[@]} -eq 0 ]]; then
    COMPOSE_ARGS=(-f "$BASE_COMPOSE_FILE")
    for override in "${PROJECT_DIR}/docker-compose.override.yml" "${PROJECT_DIR}/docker-compose.override.yaml"; do
        if [[ -f "$override" ]]; then
            COMPOSE_ARGS+=(-f "$override")
            break
        fi
    done
fi

#------------------------------------------------------------------------------
# Extract explicit container_name from compose file for a service
#------------------------------------------------------------------------------
find_explicit_name() {
    # Strategy A: ask docker compose itself for the resolved config (handles
    # multi-file merges/overrides and any indent width correctly)
    if command -v jq >/dev/null 2>&1; then
        local name
        name=$(docker compose "${COMPOSE_ARGS[@]}" config --format json 2>/dev/null | \
            jq -r --arg svc "$SERVICE" '.services[$svc].container_name // empty' 2>/dev/null) || name=""
        if [[ -n "$name" ]]; then
            echo "$name"
            return 0
        fi
    fi

    # Fallback: parse YAML directly. Indent-flexible — records the indent
    # width of the matched service key and treats any line at that width
    # or shallower as the end of the service block (compose files use
    # varying indent widths, not always exactly 2 spaces).
    awk -v svc="${SERVICE}:" '
        function indent_of(s) { match(s, /^[[:space:]]*/); return RLENGTH }
        {
            cur_indent = indent_of($0)
            trimmed = $0
            sub(/^[[:space:]]+/, "", trimmed)
        }
        !found && trimmed == svc || (!found && trimmed ~ "^"svc"[[:space:]]") {
            found = 1
            svc_indent = cur_indent
            next
        }
        found && cur_indent <= svc_indent && trimmed != "" {exit}
        found && trimmed ~ /^container_name:/ {
            gsub(/.*container_name:[[:space:]]*/, "")
            gsub(/["'"'"' ]/, "")
            print
            exit
        }
    ' "$BASE_COMPOSE_FILE" | expand_env_refs
}

# container_name values are commonly written as `${COMPOSE_PROJECT_NAME:-praxis}-mysql`.
# The `docker compose config` path above expands those for us; this raw-YAML
# fallback does not, and would otherwise return a literal `${...}` string that
# matches no container. Expand ${VAR} / ${VAR:-default} refs the way compose does.
# Only plain variable references are expanded — anything with command
# substitution or backticks is passed through untouched rather than evaluated.
expand_env_refs() {
    local line
    while IFS= read -r line; do
        if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *'"'* ]]; then
            printf '%s\n' "$line"
        else
            eval "printf '%s\n' \"${line}\""
        fi
    done
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
    compose_name=$(docker compose "${COMPOSE_ARGS[@]}" ps --format '{{.Name}}' "$SERVICE" 2>/dev/null | head -1)
    if [[ -n "$compose_name" ]] && is_running "$compose_name"; then
        echo "$compose_name"
        return 0
    fi

    # Strategy 3: Try auto-generated pattern <project>-<service>-N
    # An explicit COMPOSE_PROJECT_NAME is authoritative — deriving the name from
    # basename "$PROJECT_DIR" is wrong for git worktrees (dir `92E0E1` vs project
    # `praxis-<hash>`) and for any project that sets `name:` in its compose file.
    local project_name
    if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
        project_name="$COMPOSE_PROJECT_NAME"
    else
        project_name=$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    fi
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
    docker compose "${COMPOSE_ARGS[@]}" up -d "$SERVICE" >&2

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

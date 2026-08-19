#!/usr/bin/env bash
#
# detect-database.sh - Detect databases from docker-compose files
#
# Usage:
#   detect-database.sh [OPTIONS]
#
# Options:
#   --compose-file <path>  Path to compose file (default: auto-detect)
#   --json                 Output JSON format
#   -h, --help             Show this help message
#
# Output format (default):
#   <service>:<type>:<port>
#
# Output format (--json):
#   {"databases": [{"service": "...", "type": "...", "port": "..."}]}

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "Error: Failed to load common.sh library" >&2
    exit 1
}
source "${SCRIPT_DIR}/lib/yaml.sh"

# yaml.sh handles yq detection

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

COMPOSE_FILE=""
JSON_OUTPUT=false

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

show_help() {
    cat << EOF
detect-database.sh - Detect databases from docker-compose files

Usage:
  detect-database.sh [OPTIONS]

Options:
  --compose-file <path>  Path to compose file (default: auto-detect)
  --json                 Output JSON format
  -h, --help             Show this help message

Output format (default):
  <service>:<type>:<port>

Output format (--json):
  {"databases": [{"service": "...", "type": "...", "port": "..."}]}

Database types detected:
  - PostgreSQL (postgres)
  - MySQL (mysql)
  - MongoDB (mongo)
  - Redis (redis)
  - MinIO (minio)

Migration tools detected:
  - Alembic (alembic.ini)
  - Prisma (prisma/)
  - Knex (knexfile.*)
EOF
}

find_compose_file() {
    # Try common compose file names in order
    for filename in docker-compose.yml compose.yml docker-compose.yaml compose.yaml; do
        if [[ -f "$filename" ]]; then
            echo "$filename"
            return 0
        fi
    done

    return 1
}

detect_databases_from_compose() {
    local compose_file="$1"
    local -a databases=()

    # Parse services - get service names
    local service_names
    service_names=$(yaml_get_array '.services | keys' "$compose_file")

    # Process each service
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        # Remove quotes if present
        service=$(echo "$service" | tr -d '"')

        # Get image for this service
        local image
        image=$(yaml_get ".services[\"$service\"].image" "$compose_file")
        [[ -z "$image" ]] && continue

        # Get port (first port mapping if exists)
        local port
        port=$(yaml_get ".services[\"$service\"].ports[0]" "$compose_file")

        local db_type=""
        local db_port=""

        # Match image patterns (image may include tag like postgres:16)
        case "$image" in
            postgres*|*postgres*)
                db_type="postgresql"
                db_port="${port:-5432}"
                ;;
            mysql*|*mysql*|mariadb*|*mariadb*)
                db_type="mysql"
                db_port="${port:-3306}"
                ;;
            mongo*|*mongo*)
                db_type="mongodb"
                db_port="${port:-27017}"
                ;;
            redis*|*redis*)
                db_type="redis"
                db_port="${port:-6379}"
                ;;
            minio*|*minio*)
                db_type="minio"
                db_port="${port:-9000}"
                ;;
        esac

        # Add to databases if type detected
        if [[ -n "$db_type" ]]; then
            # Extract port number if it's in format "3000:3000" or "0.0.0.0:3000:3000"
            if [[ "$db_port" =~ :([0-9]+)$ ]]; then
                db_port="${BASH_REMATCH[1]}"
            elif [[ "$db_port" =~ ^([0-9]+): ]]; then
                db_port="${BASH_REMATCH[1]}"
            fi

            databases+=("$service:$db_type:$db_port")
        fi
    done <<< "$service_names"

    # Output results (guard against empty array under set -u on bash < 4.4)
    ((${#databases[@]})) && printf '%s\n' "${databases[@]}"
    return 0
}

detect_migration_tools() {
    local -a tools=()

    # Check for migration tool marker files
    if [[ -f "alembic.ini" ]]; then
        tools+=("alembic")
    fi

    if [[ -d "prisma" ]]; then
        tools+=("prisma")
    fi

    if ls knexfile.* >/dev/null 2>&1; then
        tools+=("knex")
    fi

    # Output results (guard against empty array under set -u on bash < 4.4)
    ((${#tools[@]})) && printf '%s\n' "${tools[@]}"
    return 0
}

#------------------------------------------------------------------------------
# Argument Parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compose-file)
            COMPOSE_FILE="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

#------------------------------------------------------------------------------
# Main Logic
#------------------------------------------------------------------------------

# Find compose file if not specified
if [[ -z "$COMPOSE_FILE" ]]; then
    COMPOSE_FILE=$(find_compose_file) || true
    if [[ -z "$COMPOSE_FILE" ]]; then
        print_warning "No compose file found"
        # Output empty result
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo '{"databases": [], "migration_tools": []}'
        fi
        exit 0
    fi
fi

# Verify compose file exists
if [[ ! -f "$COMPOSE_FILE" ]]; then
    print_error "Compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Detect databases (portable read loop instead of mapfile, for bash < 4)
databases=()
while IFS= read -r line; do
    [[ -n "$line" ]] && databases+=("$line")
done < <(detect_databases_from_compose "$COMPOSE_FILE")

# Detect migration tools (portable read loop instead of mapfile, for bash < 4)
migration_tools=()
while IFS= read -r line; do
    [[ -n "$line" ]] && migration_tools+=("$line")
done < <(detect_migration_tools)

# Output results
if [[ "$JSON_OUTPUT" == "true" ]]; then
    # JSON output
    echo "{"
    echo '  "databases": ['
    for i in "${!databases[@]}"; do
        IFS=: read -r service type port <<< "${databases[$i]}"
        echo -n "    {\"service\": \"$service\", \"type\": \"$type\", \"port\": \"$port\"}"
        if [[ $i -lt $((${#databases[@]} - 1)) ]]; then
            echo ","
        else
            echo ""
        fi
    done
    echo '  ],'
    echo '  "migration_tools": ['
    for i in "${!migration_tools[@]}"; do
        echo -n "    \"${migration_tools[$i]}\""
        if [[ $i -lt $((${#migration_tools[@]} - 1)) ]]; then
            echo ","
        else
            echo ""
        fi
    done
    echo '  ]'
    echo "}"
else
    # Plain output
    for db in "${databases[@]}"; do
        echo "$db"
    done
fi

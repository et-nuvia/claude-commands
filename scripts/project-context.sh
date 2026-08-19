#!/usr/bin/env bash
# project-context.sh - Compact structural summary of project
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/project-context.sh [--json|--raw] [--full|--services|--routes|--frontend|--models]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output
#
# Sections:
#   --services:  Docker Compose services, ports, build paths
#   --routes:    API route definitions (FastAPI/Express)
#   --frontend:  Pages and components
#   --models:    Database models (SQLAlchemy/Prisma)
#   --full:      All sections (default)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
OUTPUT_MODE="json"
SECTION="full"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

# Build a JSON array from lines of text
lines_to_json_array() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo "[]"
        return
    fi
    echo "$input" | awk '
    BEGIN { printf "[" }
    NR > 1 { printf ", " }
    { gsub(/"/, "\\\""); printf "\"%s\"", $0 }
    END { printf "]" }
    '
}

#------------------------------------------------------------------------------
# Section: Services
#------------------------------------------------------------------------------

section_services() {
    local compose_file="docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        echo '"services": []'
        return
    fi

    local services_json="["
    local first=true

    # Parse services from docker-compose.yml using grep/awk (no yq dependency)
    local service_names
    service_names=$(awk '/^services:/{found=1; next} found && /^  [a-zA-Z]/ && !/^  #/{gsub(/:.*/, ""); gsub(/^  /, ""); print} found && /^[a-zA-Z]/ && !/^services:/{exit}' "$compose_file" 2>/dev/null)

    if [[ -z "$service_names" ]]; then
        echo '"services": []'
        return
    fi

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue

        # Extract ports for this service
        local ports=""
        ports=$(awk -v svc="  ${svc}:" '
            $0 ~ "^"svc"$" || $0 ~ "^"svc" " {found=1; next}
            found && /^  [^ ]/ {exit}
            found && /- "?[0-9]/ {
                gsub(/.*- "?/, ""); gsub(/".*/, ""); gsub(/^[[:space:]]+/, "")
                printf "%s ", $0
            }
        ' "$compose_file" 2>/dev/null | xargs)

        # Extract build path
        local build_path=""
        build_path=$(awk -v svc="  ${svc}:" '
            $0 ~ "^"svc"$" || $0 ~ "^"svc" " {found=1; next}
            found && /^  [^ ]/ {exit}
            found && /build:/ {
                if (/context:/) { next }
                gsub(/.*build:\s*/, ""); gsub(/[[:space:]]+$/, ""); print; exit
            }
            found && /context:/ {
                gsub(/.*context:\s*/, ""); gsub(/[[:space:]]+$/, ""); print; exit
            }
        ' "$compose_file" 2>/dev/null)

        if [[ "$first" == "true" ]]; then
            first=false
        else
            services_json="${services_json}, "
        fi

        services_json="${services_json}{\"name\": \"${svc}\", \"ports\": \"${ports}\", \"build\": \"${build_path}\"}"
    done <<< "$service_names"

    services_json="${services_json}]"
    echo "\"services\": ${services_json}"
}

#------------------------------------------------------------------------------
# Section: Routes
#------------------------------------------------------------------------------

section_routes() {
    local routes=""

    # FastAPI/Flask routes
    local python_routes
    python_routes=$(grep -rn '@\(router\|app\)\.\(get\|post\|put\|delete\|patch\)' --include="*.py" . 2>/dev/null | head -30 | sed 's|^\./||' || true)

    # Express routes
    local express_routes
    express_routes=$(grep -rn 'router\.\(get\|post\|put\|delete\|patch\)' --include="*.ts" --include="*.js" . 2>/dev/null | head -30 | sed 's|^\./||' || true)

    routes="${python_routes}${express_routes}"

    if [[ -z "$routes" ]]; then
        echo '"routes": []'
        return
    fi

    local routes_json="["
    local first=true

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local file="${line%%:*}"
        local rest="${line#*:}"
        local lineno="${rest%%:*}"
        local content="${rest#*:}"
        content=$(echo "$content" | sed 's/^[[:space:]]*//' | sed 's/"/\\"/g')

        if [[ "$first" == "true" ]]; then
            first=false
        else
            routes_json="${routes_json}, "
        fi
        routes_json="${routes_json}{\"file\": \"${file}\", \"line\": ${lineno}, \"route\": \"${content}\"}"
    done <<< "$routes"

    routes_json="${routes_json}]"
    echo "\"routes\": ${routes_json}"
}

#------------------------------------------------------------------------------
# Section: Frontend
#------------------------------------------------------------------------------

section_frontend() {
    local pages=""

    # Next.js App Router pages
    if [[ -d "app" ]] || [[ -d "src/app" ]]; then
        local app_dir="app"
        [[ -d "src/app" ]] && app_dir="src/app"
        pages=$(find "$app_dir" -name "page.tsx" -o -name "page.jsx" -o -name "page.ts" 2>/dev/null | sort | sed 's|^\./||')
    fi

    # Next.js Pages Router
    if [[ -z "$pages" ]]; then
        if [[ -d "pages" ]] || [[ -d "src/pages" ]]; then
            local pages_dir="pages"
            [[ -d "src/pages" ]] && pages_dir="src/pages"
            pages=$(find "$pages_dir" \( -name "*.tsx" -o -name "*.jsx" \) ! -name "_*" 2>/dev/null | sort | sed 's|^\./||')
        fi
    fi

    # Components
    local components=""
    for dir in components src/components; do
        if [[ -d "$dir" ]]; then
            components=$(find "$dir" \( -name "*.tsx" -o -name "*.jsx" \) 2>/dev/null | sort | head -30 | sed 's|^\./||')
            break
        fi
    done

    local pages_arr
    pages_arr=$(lines_to_json_array "$pages")
    local components_arr
    components_arr=$(lines_to_json_array "$components")

    echo "\"frontend\": {\"pages\": ${pages_arr}, \"components\": ${components_arr}}"
}

#------------------------------------------------------------------------------
# Section: Models
#------------------------------------------------------------------------------

section_models() {
    local models=""

    # SQLAlchemy models
    local sa_models
    sa_models=$(grep -rn 'class.*\(Base\|db\.Model\)' --include="*.py" . 2>/dev/null | grep -v '__pycache__' | head -20 | sed 's|^\./||' || true)

    # Prisma schema
    local prisma_models=""
    if [[ -f "schema.prisma" ]] || [[ -f "prisma/schema.prisma" ]]; then
        local schema_file="schema.prisma"
        [[ -f "prisma/schema.prisma" ]] && schema_file="prisma/schema.prisma"
        prisma_models=$(grep '^model ' "$schema_file" 2>/dev/null | sed 's/ {//' || true)
    fi

    models="${sa_models}${prisma_models}"

    if [[ -z "$models" ]]; then
        echo '"models": []'
        return
    fi

    local models_json="["
    local first=true

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        line=$(echo "$line" | sed 's/"/\\"/g')

        if [[ "$first" == "true" ]]; then
            first=false
        else
            models_json="${models_json}, "
        fi
        models_json="${models_json}\"${line}\""
    done <<< "$models"

    models_json="${models_json}]"
    echo "\"models\": ${models_json}"
}

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --services) SECTION="services"; shift ;;
        --routes) SECTION="routes"; shift ;;
        --frontend) SECTION="frontend"; shift ;;
        --models) SECTION="models"; shift ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] [--full|--services|--routes|--frontend|--models]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# Collect sections
declare -a section_outputs=()

case "$SECTION" in
    full)
        section_outputs+=("$(section_services)")
        section_outputs+=("$(section_routes)")
        section_outputs+=("$(section_frontend)")
        section_outputs+=("$(section_models)")
        ;;
    services) section_outputs+=("$(section_services)") ;;
    routes) section_outputs+=("$(section_routes)") ;;
    frontend) section_outputs+=("$(section_frontend)") ;;
    models) section_outputs+=("$(section_models)") ;;
esac

# Build output
if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo ""
    echo "Project Context: $(basename "$PWD")"
    echo "═══════════════════════════════════"
    for s in "${section_outputs[@]}"; do
        echo "$s" | sed 's/"//g; s/,/\n/g; s/\[/\n/g; s/\]//g; s/{//g; s/}//g'
        echo ""
    done
else
    # JSON output
    local_fields=""
    for s in "${section_outputs[@]}"; do
        if [[ -n "$local_fields" ]]; then
            local_fields="${local_fields},
  "
        fi
        local_fields="${local_fields}${s}"
    done

    cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Project context loaded",
  "project": "$(basename "$PWD")",
  "timestamp": "$(date -Iseconds)",
  ${local_fields}
}
EOF
fi

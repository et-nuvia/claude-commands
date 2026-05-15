#!/usr/bin/env bash
set -euo pipefail

# Service Status Script
# Check health of all project services
# Usage: ./scripts/status.sh
# Copy to project: cp ~/.claude/scripts/status.sh ./scripts/

# Enable bash array compatibility in zsh
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt KSH_ARRAYS
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────
# Configuration - customize for your project
# ─────────────────────────────────────────
declare -A SERVICES=(
    ["API"]="http://localhost:8000/health"
    ["Frontend"]="http://localhost:3000"
    ["Database"]="localhost:5432"
    ["Redis"]="localhost:6379"
)

# ─────────────────────────────────────────
# Check functions
# ─────────────────────────────────────────
check_http() {
    local url="$1"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || echo "000")

    if [[ "${status}" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

check_tcp() {
    local host_port="$1"
    local host="${host_port%:*}"
    local port="${host_port#*:}"

    if nc -z "${host}" "${port}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

check_service() {
    local name="$1"
    local endpoint="$2"

    printf "  %-15s " "${name}"

    if [[ "${endpoint}" == http* ]]; then
        if check_http "${endpoint}"; then
            echo -e "${GREEN}● Running${NC}"
            return 0
        else
            echo -e "${RED}● Down${NC}"
            return 1
        fi
    else
        if check_tcp "${endpoint}"; then
            echo -e "${GREEN}● Running${NC}"
            return 0
        else
            echo -e "${RED}● Down${NC}"
            return 1
        fi
    fi
}

# ─────────────────────────────────────────
# Docker status
# ─────────────────────────────────────────
check_docker() {
    echo -e "\n${BLUE}Docker Containers:${NC}"

    if ! command -v docker &> /dev/null; then
        echo -e "  ${YELLOW}Docker not installed${NC}"
        return
    fi

    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
        echo -e "  ${YELLOW}No compose file or containers${NC}"
}

# ─────────────────────────────────────────
# Main
# ─────────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo -e "${BLUE}  Service Status${NC}"
echo -e "${BLUE}═══════════════════════════════════════${NC}"

echo -e "\n${BLUE}Services:${NC}"

FAILED=0
for name in "${!SERVICES[@]}"; do
    if ! check_service "${name}" "${SERVICES[${name}]}"; then
        ((FAILED++))
    fi
done

check_docker

echo -e "\n${BLUE}═══════════════════════════════════════${NC}"

if [[ ${FAILED} -eq 0 ]]; then
    echo -e "${GREEN}All services healthy${NC}"
    exit 0
else
    echo -e "${RED}${FAILED} service(s) down${NC}"
    exit 1
fi

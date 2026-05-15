#!/usr/bin/env bash
set -euo pipefail

# Wait for Service Script
# Wait for a service to become available
# Usage: wait-for-it.sh --host-port <host:port> [--timeout <seconds>]
# Copy to project: cp ~/.claude/scripts/wait-for-it.sh ./scripts/

HOST_PORT=""
TIMEOUT=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-port) HOST_PORT="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2";   shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: $0 --host-port <host:port> [--timeout <seconds>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$HOST_PORT" ]]; then
  echo "Error: --host-port is required" >&2
  echo "Usage: $0 --host-port <host:port> [--timeout <seconds>]" >&2
  exit 1
fi

HOST="${HOST_PORT%:*}"
PORT="${HOST_PORT#*:}"

echo "Waiting for ${HOST}:${PORT} (timeout: ${TIMEOUT}s)..."

for ((i=0; i<TIMEOUT; i++)); do
    if nc -z "${HOST}" "${PORT}" 2>/dev/null; then
        echo "Service ${HOST}:${PORT} is available!"
        exit 0
    fi
    sleep 1
done

echo "Timeout waiting for ${HOST}:${PORT} after ${TIMEOUT}s"
exit 1

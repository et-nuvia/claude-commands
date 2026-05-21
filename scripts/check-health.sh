#!/usr/bin/env bash
# check-health.sh - Check deployment health endpoint
# Usage: ./scripts/check-health.sh [--url <url>] [--health-path <path>] [--max-wait <seconds>]
# Returns: JSON status to stdout
# Exit codes: 0=healthy, 1=timeout, 2=error

set -euo pipefail

BASE_URL=""
HEALTH_PATH="/health"
MAX_WAIT=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)         BASE_URL="$2";    shift 2 ;;
    --health-path) HEALTH_PATH="$2"; shift 2 ;;
    --max-wait)    MAX_WAIT="$2";    shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--url <url>] [--health-path <path>] [--max-wait <seconds>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "⚠️  No URL provided - skipping health check" >&2
  cat <<EOF
{
  "status": "skipped",
  "http_code": 0,
  "endpoint": "",
  "elapsed_seconds": 0,
  "max_wait_seconds": $MAX_WAIT,
  "response": null
}
EOF
  exit 0
fi

HEALTH_ENDPOINT="${BASE_URL}${HEALTH_PATH}"
POLL_INTERVAL=5
ELAPSED=0
STATUS="timeout"
HTTP_CODE=0
RESPONSE=""
EXIT_CODE=1

RESPONSE_FILE=$(mktemp -t check-health.XXXXXX)
trap 'rm -f "$RESPONSE_FILE"' EXIT

echo "Checking health endpoint: $HEALTH_ENDPOINT" >&2

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  : > "$RESPONSE_FILE"
  HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" --max-time 10 "$HEALTH_ENDPOINT" 2>/dev/null || echo "0")
  # Strip leading zeros so JSON emission stays valid (000 is not valid JSON).
  HTTP_CODE=$((10#${HTTP_CODE:-0}))
  RESPONSE=$(cat "$RESPONSE_FILE" 2>/dev/null || echo "")

  if [[ "$HTTP_CODE" == "200" ]]; then
    STATUS="healthy"
    EXIT_CODE=0
    echo "✓ Health check passed (HTTP $HTTP_CODE)" >&2
    break
  fi

  echo "⏳ Waiting for service... (${ELAPSED}s, HTTP $HTTP_CODE)" >&2
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
  # Skip the final sleep when we're about to exit the loop.
  if [[ $ELAPSED -lt $MAX_WAIT ]]; then
    sleep "$POLL_INTERVAL"
  fi
done

# Try to parse response as JSON if available
RESPONSE_JSON=""
if [[ -n "$RESPONSE" ]]; then
  RESPONSE_JSON=$(echo "$RESPONSE" | jq -c . 2>/dev/null || echo "")
fi

# Output JSON result
cat <<EOF
{
  "status": "$STATUS",
  "http_code": $HTTP_CODE,
  "endpoint": "$HEALTH_ENDPOINT",
  "elapsed_seconds": $ELAPSED,
  "max_wait_seconds": $MAX_WAIT,
  "response": $(if [[ -n "$RESPONSE_JSON" ]]; then echo "$RESPONSE_JSON"; else echo "null"; fi)
}
EOF

exit "$EXIT_CODE"

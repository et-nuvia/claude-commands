#!/usr/bin/env bash
# monitor-pipeline.sh - Monitor CI/CD pipeline status
# Usage: ./scripts/monitor-pipeline.sh [--platform <github|gitlab>] [--branch <branch>] [--head-sha <sha>] [--max-wait <seconds>]
# Returns: JSON status to stdout with final pipeline result
# Exit codes: 0=success, 1=failure, 2=timeout
#
# When --head-sha is provided, only runs matching that commit SHA are considered.
# This prevents matching stale runs from previous pushes and catches the case where
# no new run appears (e.g., because the push didn't actually land).
#
# Migrated to use scripts/lib/git-api.sh. The two per-platform monitor
# functions were replaced with a single loop that polls
# git_pipeline_list (filtered by ref + sha) and git_pipeline_status
# via the platform adapter. Platform-specific URL construction and
# pipeline-id lookups are no longer required in this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/git-api.sh"

CI_PLATFORM=""
BRANCH="staging"
HEAD_SHA=""
MAX_WAIT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) CI_PLATFORM="$2"; shift 2 ;;
    --branch)   BRANCH="$2";     shift 2 ;;
    --head-sha) HEAD_SHA="$2";   shift 2 ;;
    --max-wait) MAX_WAIT="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--platform <github|gitlab>] [--branch <branch>] [--head-sha <sha>] [--max-wait <seconds>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# --platform is retained for backward compat. The adapter resolves
# the platform itself; if --platform was passed, honor it as an
# override.
if [[ -n "$CI_PLATFORM" ]]; then
  export GIT_ADAPTER_OVERRIDE="$CI_PLATFORM"
fi

if ! load_git_adapter; then
  echo "❌ failed to load git platform adapter" >&2
  exit 1
fi

POLL_INTERVAL=10
ELAPSED=0
STATUS="unknown"
URL=""
FAILED_STAGES=""
PIPELINE_ID=""

if [[ -n "$HEAD_SHA" ]]; then
  echo "Waiting for pipeline (branch=$BRANCH, sha=${HEAD_SHA:0:8})..." >&2
else
  echo "Waiting for pipeline (branch=$BRANCH)..." >&2
fi
# Give the platform time to queue the run.
sleep 5

monitor_loop() {
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    local args=(--ref "$BRANCH" --limit 1)
    [[ -n "$HEAD_SHA" ]] && args=(--ref "$BRANCH" --sha "$HEAD_SHA" --limit 1)
    local list pipeline
    list=$(git_pipeline_list "${args[@]}" 2>/dev/null || echo "[]")
    pipeline=$(jq -c '.[0] // empty' <<<"$list")
    if [[ -z "$pipeline" ]]; then
      if [[ -n "$HEAD_SHA" ]]; then
        echo "⏳ No run yet for ${HEAD_SHA:0:8} on $BRANCH ($((ELAPSED / 60))m)" >&2
      else
        echo "⏳ No run yet on $BRANCH ($((ELAPSED / 60))m)" >&2
      fi
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
      sleep "$POLL_INTERVAL"
      continue
    fi

    PIPELINE_ID=$(jq -r '.id' <<<"$pipeline")
    URL=$(jq -r '.url // ""' <<<"$pipeline")
    STATUS=$(jq -r '.status' <<<"$pipeline")

    case "$STATUS" in
      success)
        echo "Pipeline succeeded" >&2
        return 0
        ;;
      failed)
        local detail
        detail=$(git_pipeline_status "$PIPELINE_ID" 2>/dev/null || echo "{}")
        FAILED_STAGES=$(jq -r '.jobs[]? | select(.conclusion=="failure" or .status=="failed") | .name' <<<"$detail" \
                        | tr '\n' ',' | sed 's/,$//')
        return 1
        ;;
      cancelled)
        echo "Pipeline was cancelled" >&2
        return 1
        ;;
      *)
        echo "⏳ Pipeline running... ($((ELAPSED / 60))m, status: $STATUS)" >&2
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep "$POLL_INTERVAL"
        ;;
    esac
  done

  STATUS="timeout"
  return 2
}

monitor_loop
EXIT_CODE=$?

# Output JSON result
cat <<EOF
{
  "status": "$STATUS",
  "url": "$URL",
  "failed_stages": "$FAILED_STAGES",
  "elapsed_seconds": $ELAPSED,
  "max_wait_seconds": $MAX_WAIT
}
EOF

exit "$EXIT_CODE"

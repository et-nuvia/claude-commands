#!/usr/bin/env bash
set -euo pipefail

# Get job logs (cross-platform: GitLab/GitHub)
# Usage: pipeline-logs.sh --job-id <id> [--lines <n>]
#
# Migrated to use scripts/lib/git-api.sh. Direct gh / curl calls
# replaced with git_job_logs from the platform adapter.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/git-api.sh"

JOB_ID=""
LINES=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id) JOB_ID="$2"; shift 2 ;;
    --lines)  LINES="$2";  shift 2 ;;
    -h|--help)
      echo "Usage: $0 --job-id <id> [--lines <n>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$JOB_ID" ]]; then
  echo "Error: --job-id is required" >&2
  echo "Usage: $0 --job-id <id> [--lines <n>]" >&2
  exit 2
fi

if ! load_git_adapter; then
  echo "Error: failed to load git platform adapter" >&2
  exit 1
fi

echo "Last ${LINES} lines of job #${JOB_ID}:"
echo "========================================"
echo ""
git_job_logs "$JOB_ID" --lines "$LINES"

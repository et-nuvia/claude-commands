#!/usr/bin/env bash
set -euo pipefail

# Get job logs (cross-platform: GitLab/GitHub)
# Usage: pipeline-logs.sh --job-id <id> [--lines <n>]

source ~/.claude/scripts/git-detect.sh

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

get_gitlab_logs() {
    local job_id=$1
    local lines=$2
    local token=$(cat "$GIT_TOKEN_FILE")

    echo "Last ${lines} lines of job #${job_id}:"
    echo "========================================"
    echo ""

    curl -s --header "PRIVATE-TOKEN: ${token}" \
        "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/jobs/${job_id}/trace" \
        | tail -n "$lines"
}

get_github_logs() {
    local job_id=$1
    local lines=$2

    echo "Last ${lines} lines of job #${job_id}:"
    echo "========================================"
    echo ""

    gh run view --repo "$GIT_PROJECT_PATH" --job "$job_id" --log \
        | tail -n "$lines"
}

case "$GIT_PLATFORM" in
    gitlab)
        [[ -f "$GIT_TOKEN_FILE" ]] || { echo "Error: Token file not found: $GIT_TOKEN_FILE"; exit 1; }
        get_gitlab_logs "$JOB_ID" "$LINES"
        ;;
    github)
        command -v gh &>/dev/null || { echo "Error: gh CLI not installed"; exit 1; }
        get_github_logs "$JOB_ID" "$LINES"
        ;;
esac

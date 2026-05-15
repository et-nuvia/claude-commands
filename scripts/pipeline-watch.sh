#!/usr/bin/env bash
set -euo pipefail

# Watch pipeline until completion (cross-platform: GitLab/GitHub)
# Usage: pipeline-watch.sh [--pipeline-id <id>] [--interval <seconds>]

source ~/.claude/scripts/git-detect.sh

watch_gitlab_pipeline() {
    local pipeline_id=$1
    local token=$(cat "$GIT_TOKEN_FILE")

    if [[ -z "$pipeline_id" ]]; then
        pipeline_id=$(curl -s --header "PRIVATE-TOKEN: ${token}" \
            "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines?per_page=1" \
            | jq -r '.[0].id')
        echo "Watching latest pipeline: #${pipeline_id}"
    else
        echo "Watching pipeline: #${pipeline_id}"
    fi

    echo "Polling every ${INTERVAL}s (Ctrl+C to stop)"
    echo ""

    while true; do
        response=$(curl -s --header "PRIVATE-TOKEN: ${token}" \
            "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines/${pipeline_id}")

        status=$(echo "$response" | jq -r '.status')
        duration=$(echo "$response" | jq -r 'if .duration then "\(.duration)s" else "running..." end')

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Pipeline #${pipeline_id}: ${status} (${duration})"

        if [[ "$status" =~ ^(success|failed|canceled|skipped)$ ]]; then
            echo ""
            echo "Pipeline finished: ${status}"
            echo ""
            echo "Job Summary:"
            curl -s --header "PRIVATE-TOKEN: ${token}" \
                "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines/${pipeline_id}/jobs" \
                | jq -r '.[] | "  \(.name): \(.status)"'

            [[ "$status" == "success" ]] && exit 0 || exit 1
        fi

        sleep "$INTERVAL"
    done
}

watch_github_workflow() {
    local run_id=$1

    if [[ -z "$run_id" ]]; then
        run_id=$(gh run list --repo "$GIT_PROJECT_PATH" --limit 1 --json databaseId | jq -r '.[0].databaseId')
        echo "Watching latest workflow: #${run_id}"
    else
        echo "Watching workflow: #${run_id}"
    fi

    gh run watch "$run_id" --repo "$GIT_PROJECT_PATH" --interval "$INTERVAL"
}

PIPELINE_ID=""
INTERVAL=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline-id) PIPELINE_ID="$2"; shift 2 ;;
    --interval)    INTERVAL="$2";    shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--pipeline-id <id>] [--interval <seconds>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$GIT_PLATFORM" in
    gitlab)
        [[ -f "$GIT_TOKEN_FILE" ]] || { echo "Error: Token file not found: $GIT_TOKEN_FILE"; exit 1; }
        watch_gitlab_pipeline "$PIPELINE_ID"
        ;;
    github)
        command -v gh &>/dev/null || { echo "Error: gh CLI not installed"; exit 1; }
        watch_github_workflow "$PIPELINE_ID"
        ;;
esac

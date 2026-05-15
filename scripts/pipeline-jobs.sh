#!/usr/bin/env bash
set -euo pipefail

# List pipeline jobs (cross-platform: GitLab/GitHub)
# Usage: pipeline-jobs.sh [--pipeline-id <id>]

source ~/.claude/scripts/git-detect.sh

PIPELINE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline-id) PIPELINE_ID="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--pipeline-id <id>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

list_gitlab_jobs() {
    local pipeline_id=$1
    local token=$(cat "$GIT_TOKEN_FILE")

    if [[ -z "$pipeline_id" ]]; then
        pipeline_id=$(curl -s --header "PRIVATE-TOKEN: ${token}" \
            "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines?per_page=1" \
            | jq -r '.[0].id')
        echo "Using latest pipeline: #${pipeline_id}"
    fi

    echo "Jobs for pipeline #${pipeline_id}:"
    echo ""

    local response=$(curl -s --header "PRIVATE-TOKEN: ${token}" \
        "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines/${pipeline_id}/jobs")

    if ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
        echo "Error: Invalid JSON response from API"
        echo "$response" | head -5
        return 1
    fi

    echo "$response" | jq -r '.[] | "Job: \(.name) (ID: \(.id))\n  Stage: \(.stage)\n  Status: \(.status)\n  Duration: \(if .duration then "\(.duration)s" else "N/A" end)\n  URL: \(.web_url)\n"'
}

list_github_jobs() {
    local run_id=$1

    if [[ -z "$run_id" ]]; then
        run_id=$(gh run list --repo "$GIT_PROJECT_PATH" --limit 1 --json databaseId | jq -r '.[0].databaseId')
        echo "Using latest workflow: #${run_id}"
    fi

    echo "Jobs for workflow #${run_id}:"
    echo ""

    gh run view "$run_id" --repo "$GIT_PROJECT_PATH" --json jobs \
        | jq -r '.jobs[] | "Job: \(.name) (ID: \(.databaseId))\n  Status: \(.conclusion // .status)\n  Duration: \(.completedAt - .startedAt | if . then "\(./1000)s" else "N/A" end)\n"'
}

case "$GIT_PLATFORM" in
    gitlab)
        [[ -f "$GIT_TOKEN_FILE" ]] || { echo "Error: Token file not found: $GIT_TOKEN_FILE"; exit 1; }
        list_gitlab_jobs "$PIPELINE_ID"
        ;;
    github)
        command -v gh &>/dev/null || { echo "Error: gh CLI not installed"; exit 1; }
        list_github_jobs "$PIPELINE_ID"
        ;;
esac

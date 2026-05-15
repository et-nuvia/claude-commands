#!/usr/bin/env bash
set -euo pipefail

# Check pipeline status (cross-platform: GitLab/GitHub)
# Usage: pipeline-status.sh [--pipeline-id <id>]

source ~/.claude/scripts/git-detect.sh

get_gitlab_pipeline() {
    local pipeline_id=$1
    local token=$(cat "$GIT_TOKEN_FILE")

    if [[ -z "$pipeline_id" ]]; then
        curl -s --header "PRIVATE-TOKEN: ${token}" \
            "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines?per_page=1" \
            | jq -r '.[] | "Pipeline #\(.id)\n  Status: \(.status)\n  Ref: \(.ref)\n  SHA: \(.sha[0:8])\n  Created: \(.created_at)\n  URL: \(.web_url)"'
    else
        curl -s --header "PRIVATE-TOKEN: ${token}" \
            "${GIT_API_URL}/projects/${GIT_PROJECT_PATH}/pipelines/${pipeline_id}" \
            | jq -r '"Pipeline #\(.id)\n  Status: \(.status)\n  Ref: \(.ref)\n  SHA: \(.sha[0:8])\n  Duration: \(if .duration then "\(.duration)s" else "running" end)\n  Created: \(.created_at)\n  URL: \(.web_url)"'
    fi
}

get_github_workflow() {
    local run_id=$1

    if [[ -z "$run_id" ]]; then
        gh run list --repo "$GIT_PROJECT_PATH" --limit 1 --json number,status,conclusion,headBranch,headSha,createdAt,url \
            | jq -r '.[] | "Workflow #\(.number)\n  Status: \(.status)\n  Conclusion: \(.conclusion // "N/A")\n  Ref: \(.headBranch)\n  SHA: \(.headSha[0:8])\n  Created: \(.createdAt)\n  URL: \(.url)"'
    else
        gh run view "$run_id" --repo "$GIT_PROJECT_PATH" --json number,status,conclusion,headBranch,headSha,createdAt,url \
            | jq -r '"Workflow #\(.number)\n  Status: \(.status)\n  Conclusion: \(.conclusion // "N/A")\n  Ref: \(.headBranch)\n  SHA: \(.headSha[0:8])\n  Created: \(.createdAt)\n  URL: \(.url)"'
    fi
}

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

case "$GIT_PLATFORM" in
    gitlab)
        [[ -f "$GIT_TOKEN_FILE" ]] || { echo "Error: Token file not found: $GIT_TOKEN_FILE"; exit 1; }
        get_gitlab_pipeline "$PIPELINE_ID"
        ;;
    github)
        command -v gh &>/dev/null || { echo "Error: gh CLI not installed"; exit 1; }
        get_github_workflow "$PIPELINE_ID"
        ;;
esac

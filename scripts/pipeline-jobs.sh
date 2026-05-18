#!/usr/bin/env bash
set -euo pipefail

# List pipeline jobs (cross-platform: GitLab/GitHub)
# Usage: pipeline-jobs.sh [--pipeline-id <id>]
#
# Migrated to use scripts/lib/git-api.sh. The previous per-platform
# list_gitlab_jobs / list_github_jobs functions were collapsed onto
# git_pipeline_list (for "latest" resolution) and git_pipeline_status
# (for the jobs array on a given pipeline).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/git-api.sh"

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

if ! load_git_adapter; then
  echo "Error: failed to load git platform adapter" >&2
  exit 1
fi

if [[ -z "$PIPELINE_ID" ]]; then
  PIPELINE_ID=$(git_pipeline_list --limit 1 | jq -r '.[0].id // empty')
  if [[ -z "$PIPELINE_ID" ]]; then
    echo "Error: no recent pipelines found" >&2
    exit 1
  fi
  echo "Using latest pipeline: #${PIPELINE_ID}"
fi

echo "Jobs for pipeline #${PIPELINE_ID}:"
echo ""

git_pipeline_status "$PIPELINE_ID" \
  | jq -r '.jobs[]? | "Job: \(.name) (ID: \(.id))\n  Status: \(.conclusion // .status)\n  URL: \(.url // "")\n"'

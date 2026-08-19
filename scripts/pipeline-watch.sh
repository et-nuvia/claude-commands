#!/usr/bin/env bash
set -euo pipefail

# Watch pipeline until completion (cross-platform: GitLab/GitHub)
# Usage: pipeline-watch.sh [--pipeline-id <id>] [--interval <seconds>]
#
# Migrated to use scripts/lib/git-api.sh. The previous per-platform
# watch_gitlab_pipeline / watch_github_workflow functions are now
# git_pipeline_watch (with native gh-run-watch for GitHub and
# adapter-side polling for GitLab).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/git-api.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/gh-runs.sh"

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

if ! load_git_adapter; then
  echo "Error: failed to load git platform adapter" >&2
  exit 1
fi

if [[ -z "$PIPELINE_ID" ]]; then
  # On GitHub, "the latest run" is whichever workflow happened to start last on
  # this branch — often Dependabot or CodeQL rather than the run you mean.
  # Prefer the newest run for HEAD's SHA, then fall back to the raw latest.
  if [[ "$(git_adapter_name)" == "github" ]]; then
    _sha=$(git rev-parse HEAD 2>/dev/null || echo '')
    _branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')
    PIPELINE_ID=$(gh_runs_fetch "$_branch" 50 \
      | gh_runs_select "$_sha" "" "" \
      | jq -r '.[0].databaseId // empty')
  fi
  [[ -z "$PIPELINE_ID" ]] && PIPELINE_ID=$(git_pipeline_list --limit 1 | jq -r '.[0].id // empty')
  if [[ -z "$PIPELINE_ID" ]]; then
    echo "Error: no recent pipelines found" >&2
    exit 1
  fi
  echo "Watching latest pipeline: #${PIPELINE_ID}"
else
  echo "Watching pipeline: #${PIPELINE_ID}"
fi

git_pipeline_watch "$PIPELINE_ID" --interval "$INTERVAL"

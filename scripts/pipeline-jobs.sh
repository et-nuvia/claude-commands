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
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/gh-runs.sh"

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
  # On GitHub, "the latest run" is whichever workflow happened to start last on
  # this branch — often Dependabot or CodeQL rather than the run you mean.
  # Prefer the newest run for HEAD's SHA, then fall back to the raw latest.
  if [[ "$(git_adapter_name)" == "github" ]]; then
    gh_runs_require || exit 1
    _sha=$(git rev-parse HEAD 2>/dev/null || echo '')
    _branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')
    if ! _runs=$(gh_runs_fetch "$_branch" 50); then
      echo "Error: gh could not list runs for branch '${_branch}'" >&2
      exit 1
    fi
    PIPELINE_ID=$(printf '%s' "$_runs" \
      | gh_runs_select "$_sha" "" "" \
      | jq -r '.[0].databaseId // empty')
  fi
  [[ -z "$PIPELINE_ID" ]] && PIPELINE_ID=$(git_pipeline_list --limit 1 | jq -r '.[0].id // empty')
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

#!/usr/bin/env bash
set -euo pipefail

# Check pipeline status (cross-platform: GitLab/GitHub)
# Usage: pipeline-status.sh [--pipeline-id <id>]
#
# Migrated to use the git platform adapter shims (scripts/lib/git-api.sh).
# The previous per-platform get_gitlab_pipeline / get_github_workflow
# functions were collapsed into git_pipeline_list / git_pipeline_status
# calls that return a normalized {id, status, conclusion, sha, ref,
# url, created_at, raw} schema.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/git-api.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/gh-runs.sh"

PIPELINE_ID=""
BRANCH=""
HEAD_SHA=""
WORKFLOW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline-id) PIPELINE_ID="$2"; shift 2 ;;
    --branch)      BRANCH="$2";      shift 2 ;;
    --head-sha)    HEAD_SHA="$2";    shift 2 ;;
    --workflow)    WORKFLOW="$2";    shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--pipeline-id <id>] [--branch <branch>] [--head-sha <sha>] [--workflow <regex>]" >&2
      echo "  Without --pipeline-id, lists every workflow run for the SHA plus a combined verdict." >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! load_git_adapter; then
  echo "Error: failed to load git platform adapter" >&2
  exit 1
fi

if [[ -z "$PIPELINE_ID" ]]; then
  # One commit fans out to several workflows, so report EVERY run for the SHA
  # plus a combined verdict rather than the newest single run. Taking the
  # newest run is what let an unrelated fast workflow (Dependabot) go green
  # and stand in for a deploy that had not finished. See lib/gh-runs.sh.
  if [[ "$(git_adapter_name)" == "github" ]]; then
    branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
    sha="${HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || echo '')}"

    selected=$(gh_runs_fetch "$branch" 50 | gh_runs_select "$sha" "$WORKFLOW" "")

    if [[ "$(printf '%s' "$selected" | jq -r 'length')" == "0" ]]; then
      echo "No runs found for branch=${branch} sha=${sha:0:8} workflow=${WORKFLOW:-any}"
      exit 0
    fi

    echo "Runs for ${branch} @ ${sha:0:8} — verdict: $(printf '%s' "$selected" | gh_runs_aggregate)"
    echo ""
    printf '%s' "$selected" | jq -r '.[] |
      "Workflow: \(.workflowName)\n  Status: \(.status)\n  Conclusion: \(.conclusion // "N/A")\n  Ref: \(.headSha[0:8])\n  Created: \(.createdAt)\n  URL: \(.url)"'
  else
    # GitLab models one pipeline per ref/SHA, so the newest is unambiguous.
    data=$(git_pipeline_list --limit 1)
    echo "$data" | jq -r '.[] |
      "Pipeline #\(.id)\n  Status: \(.status)\n  Ref: \(.ref)\n  SHA: \(.sha[0:8])\n  Created: \(.created_at)\n  URL: \(.url)"'
  fi
else
  data=$(git_pipeline_status "$PIPELINE_ID")
  echo "$data" | jq -r '
    "Pipeline #\(.id)\n  Status: \(.status)\n  Conclusion: \(.conclusion // "N/A")\n  Ref: \(.raw.headBranch // .raw.ref // "")\n  SHA: \((.raw.headSha // .raw.sha // "")[0:8])\n  Created: \(.raw.createdAt // .raw.created_at // "")\n  URL: \(.raw.url // .raw.web_url // "")"'
fi

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
  # Most recent pipeline. git_pipeline_list returns a JSON array.
  data=$(git_pipeline_list --limit 1)
  echo "$data" | jq -r '.[] |
    "Pipeline #\(.id)\n  Status: \(.status)\n  Ref: \(.ref)\n  SHA: \(.sha[0:8])\n  Created: \(.created_at)\n  URL: \(.url)"'
else
  data=$(git_pipeline_status "$PIPELINE_ID")
  echo "$data" | jq -r '
    "Pipeline #\(.id)\n  Status: \(.status)\n  Conclusion: \(.conclusion // "N/A")\n  Ref: \(.raw.headBranch // .raw.ref // "")\n  SHA: \((.raw.headSha // .raw.sha // "")[0:8])\n  Created: \(.raw.createdAt // .raw.created_at // "")\n  URL: \(.raw.url // .raw.web_url // "")"'
fi

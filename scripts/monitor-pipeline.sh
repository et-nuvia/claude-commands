#!/usr/bin/env bash
# monitor-pipeline.sh - Monitor CI/CD pipeline status
# Usage: ./scripts/monitor-pipeline.sh [--platform <github|gitlab>] [--branch <branch>] [--head-sha <sha>] [--max-wait <seconds>]
# Returns: JSON status to stdout with final pipeline result
# Exit codes: 0=success, 1=failure, 2=timeout
#
# When --head-sha is provided, only runs matching that commit SHA are considered.
# This prevents matching stale runs from previous pushes and catches the case where
# no new run appears (e.g., because the push didn't actually land).
#
# Migrated to use scripts/lib/git-api.sh. The two per-platform monitor
# functions were replaced with a single loop that polls
# git_pipeline_list (filtered by ref + sha) and git_pipeline_status
# via the platform adapter. Platform-specific URL construction and
# pipeline-id lookups are no longer required in this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/git-api.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/gh-runs.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/yaml.sh"

# Workflows that routinely run alongside a deploy on the same SHA and must
# never stand in for it. Overridable via PROJECT.yaml .ci.ignore_workflows.
DEFAULT_IGNORE_WORKFLOWS='dependabot
codeql
stale
labeler'

CI_PLATFORM=""
BRANCH="staging"
HEAD_SHA=""
MAX_WAIT=600
# Newline-separated regex patterns. INCLUDE_WORKFLOWS wins when non-empty;
# otherwise EXCLUDE_WORKFLOWS filters the noise out.
INCLUDE_WORKFLOWS=""
EXCLUDE_WORKFLOWS=""
WATCHED_RUNS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) CI_PLATFORM="$2"; shift 2 ;;
    --branch)   BRANCH="$2";     shift 2 ;;
    --head-sha) HEAD_SHA="$2";   shift 2 ;;
    --max-wait) MAX_WAIT="$2";   shift 2 ;;
    --workflow)
      INCLUDE_WORKFLOWS="${INCLUDE_WORKFLOWS:+$INCLUDE_WORKFLOWS$'\n'}$2"; shift 2 ;;
    --exclude-workflow)
      EXCLUDE_WORKFLOWS="${EXCLUDE_WORKFLOWS:+$EXCLUDE_WORKFLOWS$'\n'}$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--platform <github|gitlab>] [--branch <branch>] [--head-sha <sha>] [--max-wait <seconds>]" >&2
      echo "            [--workflow <regex>]... [--exclude-workflow <regex>]..." >&2
      echo "  --workflow          watch only these workflows (repeatable, unanchored case-insensitive regex)." >&2
      echo "                      Defaults to PROJECT.yaml .ci.workflows.<branch-role>." >&2
      echo "  --exclude-workflow  ignore these workflows (repeatable). Defaults to" >&2
      echo "                      PROJECT.yaml .ci.ignore_workflows, else a built-in noise list." >&2
      echo "  Every watched run must succeed; a filter matching no run never reports success." >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Map the branch being watched back to its PROJECT.yaml role (dev/staging/
# production) so `.ci.workflows.<role>` can name the workflow that actually
# gates that environment.
resolve_branch_role() {
  local repo_root project_yaml role
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  project_yaml="${repo_root}/PROJECT.yaml"
  [[ -f "$project_yaml" ]] || return 0
  declare -F yaml_get_default >/dev/null || return 0

  for role in production staging dev; do
    if [[ "$(yaml_get_default ".ci.branches.${role}" "" "$project_yaml")" == "$BRANCH" ]]; then
      echo "$role"
      return 0
    fi
  done
}

# Read a PROJECT.yaml list (.ci.ignore_workflows) as newline-separated patterns.
resolve_yaml_list() {
  local path="$1" repo_root project_yaml
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  project_yaml="${repo_root}/PROJECT.yaml"
  [[ -f "$project_yaml" ]] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  yq -r "${path} // [] | .[]" "$project_yaml" 2>/dev/null || true
}

if [[ -z "$INCLUDE_WORKFLOWS" ]]; then
  BRANCH_ROLE="$(resolve_branch_role)"
  if [[ -n "$BRANCH_ROLE" ]] && declare -F yaml_get_default >/dev/null; then
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    INCLUDE_WORKFLOWS="$(yaml_get_default ".ci.workflows.${BRANCH_ROLE}" "" "${_repo_root}/PROJECT.yaml")"
  fi
fi

if [[ -z "$EXCLUDE_WORKFLOWS" ]]; then
  EXCLUDE_WORKFLOWS="$(resolve_yaml_list '.ci.ignore_workflows')"
  [[ -z "$EXCLUDE_WORKFLOWS" ]] && EXCLUDE_WORKFLOWS="$DEFAULT_IGNORE_WORKFLOWS"
fi

# --platform is retained for backward compat. The adapter resolves
# the platform itself; if --platform was passed, honor it as an
# override.
if [[ -n "$CI_PLATFORM" ]]; then
  export GIT_ADAPTER_OVERRIDE="$CI_PLATFORM"
fi

if ! load_git_adapter; then
  echo "❌ failed to load git platform adapter" >&2
  exit 1
fi

# Assert gh is usable BEFORE the poll loop. Inside the loop an unanswerable
# query is indistinguishable from "no run yet", so a missing or unauthenticated
# gh would spin silently until --max-wait and then report a timeout rather than
# the real cause — on the very command a deploy gates on.
if [[ "$(git_adapter_name)" == "github" ]]; then
  gh_runs_require || exit 1
fi

POLL_INTERVAL=10
ELAPSED=0
STATUS="unknown"
URL=""
FAILED_STAGES=""
PIPELINE_ID=""

if [[ -n "$HEAD_SHA" ]]; then
  echo "Waiting for pipeline (branch=$BRANCH, sha=${HEAD_SHA:0:8})..." >&2
else
  echo "Waiting for pipeline (branch=$BRANCH)..." >&2
fi
# Give the platform time to queue the run.
sleep 5

monitor_loop() {
  local announced=""
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    # ── GitHub: one commit fans out to several workflows ──────────────────
    # Watching only the newest run is unsafe: a fast noise workflow
    # (Dependabot, lint) can go green on the same SHA while the deploy is
    # still running, and the caller then tags and promotes an unfinished
    # deploy. Watch EVERY matching run and require all of them. See
    # lib/gh-runs.sh for the selection rules.
    if [[ "$(git_adapter_name)" == "github" ]]; then
      local runs selected verdict
      # gh_runs_require already proved gh is usable, so a failure here is a
      # transient (network, rate limit) rather than a misconfiguration — keep
      # polling rather than aborting a deploy watch on one bad call.
      runs="$(gh_runs_fetch "$BRANCH" 50 || true)"
      selected="$(printf '%s' "$runs" | gh_runs_select "$HEAD_SHA" "$INCLUDE_WORKFLOWS" "$EXCLUDE_WORKFLOWS")"
      verdict="$(printf '%s' "$selected" | gh_runs_aggregate)"

      PIPELINE_ID="$(printf '%s' "$selected" | jq -r '.[0].databaseId // ""')"
      URL="$(printf '%s' "$selected" | jq -r '.[0].url // ""')"
      WATCHED_RUNS="$(printf '%s' "$selected" \
        | jq -r 'map("\(.workflowName):\(.conclusion // .status)") | join(", ")')"

      # Print the matched runs once, so the verdict is always attributable.
      if [[ -z "$announced" && "$verdict" != "none" ]]; then
        printf '%s' "$selected" | gh_runs_describe | sed 's/^/  → /' >&2
        announced=1
      fi

      case "$verdict" in
        success)
          echo "Pipeline succeeded ($(printf '%s' "$selected" | jq -r 'length') workflow(s))" >&2
          STATUS="success"
          return 0
          ;;
        failure)
          STATUS="failure"
          FAILED_STAGES="$(
            printf '%s' "$selected" \
              | jq -r '.[] | select(.conclusion | IN("failure","timed_out","startup_failure")) | .databaseId' \
              | while read -r rid; do gh_runs_failed_jobs "$rid"; done \
              | paste -sd, - | sed 's/,\{2,\}/,/g; s/^,//; s/,$//'
          )"
          return 1
          ;;
        none)
          echo "⏳ No run yet for ${HEAD_SHA:0:8} on $BRANCH ($((ELAPSED / 60))m)" >&2
          ;;
        *)
          echo "⏳ Pipeline running... ($((ELAPSED / 60))m, verdict: $verdict)" >&2
          ;;
      esac
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
      sleep "$POLL_INTERVAL"
      continue
    fi

    # ── GitLab: one pipeline per ref/SHA, so the newest is unambiguous ────
    local args=(--ref "$BRANCH" --limit 1)
    [[ -n "$HEAD_SHA" ]] && args=(--ref "$BRANCH" --sha "$HEAD_SHA" --limit 1)
    local list pipeline
    list=$(git_pipeline_list "${args[@]}" 2>/dev/null || echo "[]")
    pipeline=$(jq -c '.[0] // empty' <<<"$list")
    if [[ -z "$pipeline" ]]; then
      if [[ -n "$HEAD_SHA" ]]; then
        echo "⏳ No run yet for ${HEAD_SHA:0:8} on $BRANCH ($((ELAPSED / 60))m)" >&2
      else
        echo "⏳ No run yet on $BRANCH ($((ELAPSED / 60))m)" >&2
      fi
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
      sleep "$POLL_INTERVAL"
      continue
    fi

    PIPELINE_ID=$(jq -r '.id' <<<"$pipeline")
    URL=$(jq -r '.url // ""' <<<"$pipeline")
    STATUS=$(jq -r '.status' <<<"$pipeline")

    case "$STATUS" in
      success)
        echo "Pipeline succeeded" >&2
        return 0
        ;;
      failed)
        local detail
        detail=$(git_pipeline_status "$PIPELINE_ID" 2>/dev/null || echo "{}")
        FAILED_STAGES=$(jq -r '.jobs[]? | select(.conclusion=="failure" or .status=="failed") | .name' <<<"$detail" \
                        | tr '\n' ',' | sed 's/,$//')
        return 1
        ;;
      cancelled)
        echo "Pipeline was cancelled" >&2
        return 1
        ;;
      *)
        echo "⏳ Pipeline running... ($((ELAPSED / 60))m, status: $STATUS)" >&2
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep "$POLL_INTERVAL"
        ;;
    esac
  done

  STATUS="timeout"
  return 2
}

monitor_loop
EXIT_CODE=$?

# Output JSON result
cat <<EOF
{
  "status": "$STATUS",
  "url": "$URL",
  "failed_stages": "$FAILED_STAGES",
  "watched_runs": "$WATCHED_RUNS",
  "elapsed_seconds": $ELAPSED,
  "max_wait_seconds": $MAX_WAIT
}
EOF

exit "$EXIT_CODE"

#!/usr/bin/env bash
# monitor-pipeline.sh - Monitor CI/CD pipeline status
# Usage: ./scripts/monitor-pipeline.sh [--platform <github|gitlab>] [--branch <branch>] [--head-sha <sha>] [--max-wait <seconds>]
# Returns: JSON status to stdout with final pipeline result
# Exit codes: 0=success, 1=failure, 2=timeout
#
# When --head-sha is provided, only runs matching that commit SHA are considered.
# This prevents matching stale runs from previous pushes and catches the case where
# no new run appears (e.g., because the push didn't actually land).

set -euo pipefail

# Detect CI platform if not provided
detect_ci_platform() {
  # Tier 1: Git remote URL parsing
  local remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
  if [[ "$remote_url" =~ github\.com ]]; then
    echo "github"
    return 0
  elif [[ "$remote_url" =~ gitlab || "$remote_url" =~ git\. ]]; then
    echo "gitlab"
    return 0
  fi

  # Tier 2: Check for CLI tools
  if command -v gh >/dev/null 2>&1; then
    echo "github"
    return 0
  elif command -v gitlab >/dev/null 2>&1 || command -v glab >/dev/null 2>&1; then
    echo "gitlab"
    return 0
  fi

  # Tier 3: Default to github (most common)
  echo "github"
}

CI_PLATFORM=""
BRANCH="staging"
HEAD_SHA=""
MAX_WAIT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) CI_PLATFORM="$2"; shift 2 ;;
    --branch)   BRANCH="$2";     shift 2 ;;
    --head-sha) HEAD_SHA="$2";   shift 2 ;;
    --max-wait) MAX_WAIT="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--platform <github|gitlab>] [--branch <branch>] [--head-sha <sha>] [--max-wait <seconds>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Auto-detect platform if not provided
if [[ -z "$CI_PLATFORM" ]]; then
  CI_PLATFORM=$(detect_ci_platform)
  echo "⚠️  CI platform not specified, detected: $CI_PLATFORM" >&2
fi

POLL_INTERVAL=10
ELAPSED=0
STATUS="unknown"
URL=""
FAILED_STAGES=""

monitor_github() {
  if [[ -n "$HEAD_SHA" ]]; then
    echo "Waiting for GitHub Actions pipeline (branch=$BRANCH, sha=${HEAD_SHA:0:8})..." >&2
  else
    echo "Waiting for GitHub Actions pipeline (branch=$BRANCH)..." >&2
  fi
  sleep 5  # Give GitHub time to queue the run

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if [[ -n "$HEAD_SHA" ]]; then
      # Only consider runs whose headSha matches the commit we're watching for.
      # This prevents matching stale runs from prior pushes (which would return
      # an immediate false-positive success) and forces a timeout if no new run
      # ever appears (e.g., because the push didn't land on the remote).
      RUN_ID=$(gh run list --branch "$BRANCH" --limit 20 \
        --json databaseId,headSha \
        --jq "[.[] | select(.headSha == \"$HEAD_SHA\")][0].databaseId" 2>/dev/null || echo "")
      if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
        echo "⏳ No run yet for ${HEAD_SHA:0:8} on $BRANCH ($((ELAPSED / 60))m)" >&2
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep $POLL_INTERVAL
        continue
      fi
    else
      RUN_ID=$(gh run list --branch "$BRANCH" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
      if [[ -z "$RUN_ID" ]]; then
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep $POLL_INTERVAL
        continue
      fi
    fi

    STATUS=$(gh run view "$RUN_ID" --json conclusion -q '.conclusion' 2>/dev/null || echo "")
    URL="https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$RUN_ID"

    case "$STATUS" in
      success)
        echo "Pipeline succeeded" >&2
        return 0
        ;;
      failure)
        FAILED_STAGES=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        return 1
        ;;
      cancelled)
        echo "Pipeline was cancelled" >&2
        return 1
        ;;
      *)
        echo "⏳ Pipeline running... ($((ELAPSED / 60))m)" >&2
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep $POLL_INTERVAL
        ;;
    esac
  done

  STATUS="timeout"
  return 2
}

monitor_gitlab() {
  GITLAB_TOKEN=$(cat ~/.gitlab-token 2>/dev/null || echo "")
  if [[ -z "$GITLAB_TOKEN" ]]; then
    echo "❌ GitLab token not found at ~/.gitlab-token" >&2
    return 1
  fi

  GITLAB_INSTANCE="git.turnersrus.com"
  PROJECT_PATH=$(git config --get remote.origin.url | sed 's/.*:\(.*\)\.git/\1/')
  PROJECT_ID=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://$GITLAB_INSTANCE/api/v4/projects?search=$PROJECT_PATH" | jq -r '.[0].id')

  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
    echo "❌ Could not determine GitLab project ID" >&2
    return 1
  fi

  if [[ -n "$HEAD_SHA" ]]; then
    echo "Waiting for GitLab CI pipeline (ref=$BRANCH, sha=${HEAD_SHA:0:8})..." >&2
  else
    echo "Waiting for GitLab CI pipeline (ref=$BRANCH)..." >&2
  fi
  sleep 5

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if [[ -n "$HEAD_SHA" ]]; then
      # GitLab supports filtering pipelines by sha directly
      PIPELINE_DATA=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://$GITLAB_INSTANCE/api/v4/projects/$PROJECT_ID/pipelines?ref=$BRANCH&sha=$HEAD_SHA&per_page=1" | jq '.[0]')
      if [[ -z "$PIPELINE_DATA" || "$PIPELINE_DATA" == "null" ]]; then
        echo "⏳ No pipeline yet for ${HEAD_SHA:0:8} on $BRANCH ($((ELAPSED / 60))m)" >&2
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep $POLL_INTERVAL
        continue
      fi
    else
      PIPELINE_DATA=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://$GITLAB_INSTANCE/api/v4/projects/$PROJECT_ID/pipelines?ref=$BRANCH&per_page=1" | jq '.[0]')
    fi

    PIPELINE_ID=$(echo "$PIPELINE_DATA" | jq -r '.id')
    STATUS=$(echo "$PIPELINE_DATA" | jq -r '.status')
    URL=$(echo "$PIPELINE_DATA" | jq -r '.web_url')

    case "$STATUS" in
      success)
        echo "Pipeline succeeded" >&2
        return 0
        ;;
      failed)
        FAILED_STAGES=$(echo "$PIPELINE_DATA" | jq -r '.[]?.jobs[]? | select(.status=="failed") | .stage' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
        return 1
        ;;
      canceled)
        echo "Pipeline was cancelled" >&2
        return 1
        ;;
      *)
        echo "⏳ Pipeline running... ($((ELAPSED / 60))m, status: $STATUS)" >&2
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        sleep $POLL_INTERVAL
        ;;
    esac
  done

  STATUS="timeout"
  return 2
}

# Run appropriate monitoring
if [[ "$CI_PLATFORM" == "github" ]]; then
  monitor_github
  EXIT_CODE=$?
elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
  monitor_gitlab
  EXIT_CODE=$?
else
  echo "❌ Unknown CI platform: $CI_PLATFORM" >&2
  exit 1
fi

# Output JSON result
cat <<EOF
{
  "status": "$STATUS",
  "url": "$URL",
  "failed_stages": "$FAILED_STAGES",
  "elapsed_seconds": $ELAPSED,
  "max_wait_seconds": $MAX_WAIT
}
EOF

exit "$EXIT_CODE"

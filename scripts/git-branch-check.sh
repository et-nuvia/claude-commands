#!/usr/bin/env bash
# git-branch-check.sh - Validate git branch state
# Usage: ./scripts/git-branch-check.sh --branch <branch> [--exists] [--clean] [--synced]
# Returns: JSON with validation results
# Exit codes: 0=valid, 1=invalid

set -euo pipefail

BRANCH=""
CHECK_EXISTS=false
CHECK_CLEAN=false
CHECK_SYNCED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --exists)
      CHECK_EXISTS=true
      shift
      ;;
    --clean)
      CHECK_CLEAN=true
      shift
      ;;
    --synced)
      CHECK_SYNCED=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 --branch <branch> [--exists] [--clean] [--synced]" >&2
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      echo "Usage: $0 --branch <branch> [--exists] [--clean] [--synced]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BRANCH" ]]; then
  echo "❌ Usage: $0 --branch <branch> [--exists] [--clean] [--synced]" >&2
  exit 2
fi

# If no checks specified, run all checks
if [[ "$CHECK_EXISTS" == "false" && "$CHECK_CLEAN" == "false" && "$CHECK_SYNCED" == "false" ]]; then
  CHECK_EXISTS=true
  CHECK_CLEAN=true
  CHECK_SYNCED=true
fi

CHECKS_RUN=0
CHECKS_PASSED=0
CHECK_RESULTS=()
ERRORS=()
WARNINGS=()

echo "Validating branch: $BRANCH" >&2

# ============================================================================
# Check: Branch Exists
# ============================================================================

if [[ "$CHECK_EXISTS" == "true" ]]; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "  Checking if branch exists..." >&2

  # Fetch latest
  git fetch origin "$BRANCH" >/dev/null 2>&1 || true

  # Check local branch
  LOCAL_EXISTS=false
  if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    LOCAL_EXISTS=true
  fi

  # Check remote branch
  REMOTE_EXISTS=false
  if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    REMOTE_EXISTS=true
  fi

  if [[ "$LOCAL_EXISTS" == "true" || "$REMOTE_EXISTS" == "true" ]]; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECK_RESULTS+=("{\"check\":\"exists\",\"status\":\"passed\",\"local\":$LOCAL_EXISTS,\"remote\":$REMOTE_EXISTS}")
    echo "    ✓ Branch exists (local: $LOCAL_EXISTS, remote: $REMOTE_EXISTS)" >&2
  else
    CHECK_RESULTS+=("{\"check\":\"exists\",\"status\":\"failed\",\"local\":false,\"remote\":false}")
    ERRORS+=("Branch does not exist: $BRANCH")
    echo "    ✗ Branch does not exist" >&2
  fi
fi

# ============================================================================
# Check: Working Directory Clean
# ============================================================================

if [[ "$CHECK_CLEAN" == "true" ]]; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "  Checking if working directory is clean..." >&2

  # Get current branch
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [[ "$CURRENT_BRANCH" == "$BRANCH" ]]; then
    # Check for uncommitted changes
    UNCOMMITTED_FILES=$(git status --porcelain | wc -l | tr -d ' ')

    if [[ $UNCOMMITTED_FILES -eq 0 ]]; then
      CHECKS_PASSED=$((CHECKS_PASSED + 1))
      CHECK_RESULTS+=("{\"check\":\"clean\",\"status\":\"passed\",\"uncommitted_files\":0}")
      echo "    ✓ Working directory is clean" >&2
    else
      CHECK_RESULTS+=("{\"check\":\"clean\",\"status\":\"failed\",\"uncommitted_files\":$UNCOMMITTED_FILES}")
      ERRORS+=("Working directory has $UNCOMMITTED_FILES uncommitted changes")
      echo "    ✗ Working directory has uncommitted changes" >&2
    fi
  else
    # Not on the target branch, can't check
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECK_RESULTS+=("{\"check\":\"clean\",\"status\":\"skipped\",\"reason\":\"not on branch\"}")
    WARNINGS+=("Not on branch $BRANCH (current: $CURRENT_BRANCH), skipped clean check")
    echo "    ⚠️  Not on target branch, skipped" >&2
  fi
fi

# ============================================================================
# Check: Branch Synced with Remote
# ============================================================================

if [[ "$CHECK_SYNCED" == "true" ]]; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "  Checking if branch is synced with remote..." >&2

  # Fetch latest
  git fetch origin "$BRANCH" >/dev/null 2>&1 || true

  # Check if both local and remote exist
  LOCAL_EXISTS=false
  REMOTE_EXISTS=false

  if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    LOCAL_EXISTS=true
  fi

  if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    REMOTE_EXISTS=true
  fi

  if [[ "$LOCAL_EXISTS" == "true" && "$REMOTE_EXISTS" == "true" ]]; then
    # Compare local and remote
    LOCAL_HASH=$(git rev-parse "$BRANCH")
    REMOTE_HASH=$(git rev-parse "origin/$BRANCH")

    if [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]]; then
      CHECKS_PASSED=$((CHECKS_PASSED + 1))
      CHECK_RESULTS+=("{\"check\":\"synced\",\"status\":\"passed\",\"local_hash\":\"$LOCAL_HASH\",\"remote_hash\":\"$REMOTE_HASH\"}")
      echo "    ✓ Branch is synced with remote" >&2
    else
      # Check if local is ahead or behind
      AHEAD=$(git rev-list --count "origin/$BRANCH".."$BRANCH" 2>/dev/null || echo "0")
      BEHIND=$(git rev-list --count "$BRANCH".."origin/$BRANCH" 2>/dev/null || echo "0")

      CHECK_RESULTS+=("{\"check\":\"synced\",\"status\":\"failed\",\"ahead\":$AHEAD,\"behind\":$BEHIND}")
      ERRORS+=("Branch out of sync: $AHEAD ahead, $BEHIND behind")
      echo "    ✗ Branch out of sync ($AHEAD ahead, $BEHIND behind)" >&2
    fi
  elif [[ "$LOCAL_EXISTS" == "true" ]]; then
    # Local only
    CHECK_RESULTS+=("{\"check\":\"synced\",\"status\":\"failed\",\"reason\":\"no remote\"}")
    ERRORS+=("Local branch exists but no remote branch")
    echo "    ✗ No remote branch" >&2
  elif [[ "$REMOTE_EXISTS" == "true" ]]; then
    # Remote only
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECK_RESULTS+=("{\"check\":\"synced\",\"status\":\"passed\",\"reason\":\"remote only\"}")
    echo "    ✓ Remote branch exists (no local branch)" >&2
  else
    # Neither exists
    CHECK_RESULTS+=("{\"check\":\"synced\",\"status\":\"failed\",\"reason\":\"neither exists\"}")
    ERRORS+=("Branch does not exist locally or remotely")
    echo "    ✗ Branch does not exist" >&2
  fi
fi

# ============================================================================
# Generate Results
# ============================================================================

# Determine overall status
if [[ ${#ERRORS[@]} -eq 0 ]]; then
  OVERALL_STATUS="valid"
  EXIT_CODE=0
else
  OVERALL_STATUS="invalid"
  EXIT_CODE=1
fi

# Build errors and warnings JSON arrays
ERRORS_JSON="[]"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  ERRORS_JSON="[$(printf '"%s",' "${ERRORS[@]}" | sed 's/,$//')"]"
fi

WARNINGS_JSON="[]"
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  WARNINGS_JSON="[$(printf '"%s",' "${WARNINGS[@]}" | sed 's/,$//')"]"
fi

echo "" >&2
echo "Results: $CHECKS_PASSED/$CHECKS_RUN checks passed" >&2

# Output JSON result
cat <<EOF
{
  "status": "$OVERALL_STATUS",
  "branch": "$BRANCH",
  "checks_run": $CHECKS_RUN,
  "checks_passed": $CHECKS_PASSED,
  "checks_failed": $((CHECKS_RUN - CHECKS_PASSED)),
  "checks": [$(IFS=,; echo "${CHECK_RESULTS[*]}")],
  "errors": $ERRORS_JSON,
  "warnings": $WARNINGS_JSON
}
EOF

exit "$EXIT_CODE"

#!/usr/bin/env bash
# deployment-rollback.sh - Proper deployment rollback mechanism
# Usage: ./scripts/deployment-rollback.sh --branch <branch> --reason <reason> [--force]
# Returns: JSON rollback result to stdout
# Exit codes: 0=success, 1=failure, 2=error

set -euo pipefail

# Parse arguments
BRANCH=""
REASON=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --force)  FORCE=true;  shift ;;
    -h|--help)
      echo "Usage: $0 --branch <branch> --reason <reason> [--force]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BRANCH" || -z "$REASON" ]]; then
  echo "❌ Usage: $0 --branch <branch> --reason <reason> [--force]" >&2
  exit 2
fi

echo "Preparing rollback on $BRANCH..." >&2
echo "  Reason: $REASON" >&2

# Fetch latest
git fetch origin "$BRANCH" >/dev/null 2>&1 || true

# Verify branch exists
if ! git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
  echo "❌ Branch not found: $BRANCH" >&2
  cat <<EOF
{
  "success": false,
  "error": "Branch not found: $BRANCH"
}
EOF
  exit 2
fi

# Checkout branch
if ! git checkout "$BRANCH" >/dev/null 2>&1; then
  cat <<EOF
{
  "success": false,
  "branch": "$BRANCH",
  "error": "Failed to checkout $BRANCH (uncommitted changes or invalid branch)"
}
EOF
  exit 2
fi
if ! git pull origin "$BRANCH" >/dev/null 2>&1; then
  cat <<EOF
{
  "success": false,
  "branch": "$BRANCH",
  "error": "Failed to pull origin/$BRANCH (diverged or network failure) — refusing to revert from stale state"
}
EOF
  exit 2
fi

# Get current HEAD before revert
ORIGINAL_HASH=$(git rev-parse HEAD)

# Create revert commit
REVERT_MESSAGE="revert(deploy): rollback due to $REASON"

echo "Creating revert commit..." >&2
if git revert -n HEAD >/dev/null 2>&1; then
  # Commit the revert
  if git commit -m "$REVERT_MESSAGE" >/dev/null 2>&1; then
    REVERT_HASH=$(git rev-parse HEAD)
    echo "✓ Revert commit created: $REVERT_HASH" >&2

    # Push to remote
    if git push origin "$BRANCH" >/dev/null 2>&1; then
      echo "✓ Rollback pushed to remote" >&2

      cat <<EOF
{
  "success": true,
  "branch": "$BRANCH",
  "original_hash": "$ORIGINAL_HASH",
  "revert_hash": "$REVERT_HASH",
  "reason": "$REASON",
  "message": "$REVERT_MESSAGE",
  "pushed": true
}
EOF
      exit 0
    else
      echo "⚠️  Revert created but push failed — unwinding local revert to keep branch in sync with origin" >&2
      # Without this reset, a retry would revert HEAD (the failed local revert)
      # and produce a revert-of-revert.
      git reset --hard "$ORIGINAL_HASH" >/dev/null 2>&1 || true

      cat <<EOF
{
  "success": false,
  "branch": "$BRANCH",
  "original_hash": "$ORIGINAL_HASH",
  "revert_hash": "$REVERT_HASH",
  "error": "Failed to push rollback to remote (local revert unwound)"
}
EOF
      exit 2
    fi
  else
    echo "❌ Failed to commit revert" >&2
    git revert --abort >/dev/null 2>&1 || true

    cat <<EOF
{
  "success": false,
  "branch": "$BRANCH",
  "error": "Failed to commit revert"
}
EOF
    exit 1
  fi
else
  echo "❌ Revert failed" >&2
  REVERT_ERROR=$(git status --short 2>&1 || echo "Unknown error")

  git revert --abort >/dev/null 2>&1 || true

  cat <<EOF
{
  "success": false,
  "branch": "$BRANCH",
  "error": "Revert operation failed: $REVERT_ERROR"
}
EOF
  exit 1
fi

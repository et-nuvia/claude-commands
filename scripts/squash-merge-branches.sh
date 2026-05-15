#!/usr/bin/env bash
# squash-merge-branches.sh - Safely perform squash merge from dev to staging
# Usage: ./scripts/squash-merge-branches.sh --dev-branch <branch> --staging-branch <branch>
# Returns: JSON merge result to stdout
# Exit codes: 0=success, 1=conflict, 2=error
#
# Commit message format:
#   Subject: type(scopes): concise summary of what changed
#   Body: individual conventional commit lines for pipeline changelog parsing
#
# The pipeline parses both the subject AND body lines that match conventional
# commit format (feat/fix/refactor/perf), so each meaningful change gets its
# own entry in the release notes.

set -euo pipefail

# Guard: deploy scripts must run from main checkout, not a worktree (DSN Decision 4)
_SMB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_SMB_DIR}/lib/worktree-utils.sh" ]]; then
    # shellcheck disable=SC1091
    source "${_SMB_DIR}/lib/worktree-utils.sh" 2>/dev/null || true
    if declare -f is_in_worktree &>/dev/null && is_in_worktree; then
        echo '{"status":"error","message":"Deploy scripts must run from the main checkout, not a worktree"}' >&2
        exit 1
    fi
fi

DEV_BRANCH=""
STAGING_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev-branch)     DEV_BRANCH="$2";     shift 2 ;;
    --staging-branch) STAGING_BRANCH="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --dev-branch <branch> --staging-branch <branch>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DEV_BRANCH" || -z "$STAGING_BRANCH" ]]; then
  echo "❌ Usage: $0 --dev-branch <branch> --staging-branch <branch>" >&2
  exit 2
fi

echo "Preparing squash merge..." >&2
echo "  From: $DEV_BRANCH" >&2
echo "  To: $STAGING_BRANCH" >&2

# Fetch latest branches
git fetch origin "$DEV_BRANCH" "$STAGING_BRANCH" >/dev/null 2>&1 || true

# Verify branches exist
if ! git rev-parse --verify "origin/$DEV_BRANCH" >/dev/null 2>&1; then
  echo "❌ Dev branch not found: $DEV_BRANCH" >&2
  cat <<EOF
{
  "success": false,
  "error": "Dev branch not found: $DEV_BRANCH"
}
EOF
  exit 2
fi

if ! git rev-parse --verify "origin/$STAGING_BRANCH" >/dev/null 2>&1; then
  echo "❌ Staging branch not found: $STAGING_BRANCH" >&2
  cat <<EOF
{
  "success": false,
  "error": "Staging branch not found: $STAGING_BRANCH"
}
EOF
  exit 2
fi

# Checkout staging branch
git checkout "$STAGING_BRANCH" >/dev/null 2>&1
git pull origin "$STAGING_BRANCH" >/dev/null 2>&1

# Generate a conventional commit message from the actual changes being merged.
#
# Subject line: type(scopes): summary derived from commit history
# Body: individual conventional commit subjects (feat/fix/refactor/perf only)
#       so the pipeline can parse each one as a separate changelog entry.
generate_commit_message() {
  local dev="$1"
  local staging="$2"
  local range="origin/${staging}..origin/${dev}"

  # ── Determine type from commit frequency ──
  local feat_count fix_count refactor_count
  feat_count=$(git log "$range" --oneline 2>/dev/null | grep -c "^[a-f0-9]* feat" || true)
  fix_count=$(git log "$range" --oneline 2>/dev/null | grep -c "^[a-f0-9]* fix" || true)
  refactor_count=$(git log "$range" --oneline 2>/dev/null | grep -c "^[a-f0-9]* refactor" || true)

  local type="feat"
  if [[ "$fix_count" -gt "$feat_count" && "$fix_count" -gt "$refactor_count" ]]; then
    type="fix"
  elif [[ "$refactor_count" -gt "$feat_count" && "$refactor_count" -gt "$fix_count" ]]; then
    type="refactor"
  fi

  # ── Determine scopes from changed files ──
  local scopes=""
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
      src/components/*|src/pages/*) scopes="$scopes ui" ;;
      server/routes/*|server/services/*) scopes="$scopes api" ;;
      server/config/*) scopes="$scopes config" ;;
      server/queues/*) scopes="$scopes queue" ;;
      scripts/*) scopes="$scopes scripts" ;;
      Dockerfile*|docker-compose*) scopes="$scopes docker" ;;
      .github/*|.gitlab-ci*) scopes="$scopes ci" ;;
    esac
  done < <(git diff --cached --name-only 2>/dev/null)

  local unique_scopes
  unique_scopes=$(echo "$scopes" | tr ' ' '\n' | sort -u | head -2 | tr '\n' ',' | sed 's/,$//')

  # ── Collect meaningful commit subjects ──
  # Only feat/fix/refactor/perf — skip docs, chore, test, merge, revert
  local commits=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Strip hash prefix, keep full conventional commit subject
    local subject
    subject=$(echo "$line" | sed -E 's/^[a-f0-9]+ //')
    # Clean up "# Task: " noise
    subject=$(echo "$subject" | sed 's/# Task: //')
    commits="${commits}${subject}"$'\n'
  done < <(git log "$range" --oneline --no-merges \
    --grep="^feat" --grep="^fix" --grep="^refactor" --grep="^perf" 2>/dev/null \
    | grep -v "^[a-f0-9]* docs\|^[a-f0-9]* chore\|^[a-f0-9]* test(\|^[a-f0-9]* merge\|^[a-f0-9]* revert")

  # Remove trailing newline
  commits=$(echo "$commits" | sed '/^$/d')

  # ── Build subject line from top commits ──
  # Take the top 3 commit descriptions (without type prefix) for a human summary
  local summary_parts=""
  local count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ $count -ge 3 ]] && break
    local desc
    desc=$(echo "$line" | sed -E 's/^[a-z]+(\([^)]*\))?: //')
    if [[ -n "$desc" ]]; then
      if [[ -n "$summary_parts" ]]; then
        summary_parts="${summary_parts}, ${desc}"
      else
        summary_parts="$desc"
      fi
      count=$((count + 1))
    fi
  done <<< "$commits"

  # Truncate if too long for subject (72 char limit minus type prefix)
  local max_desc_len=$((72 - ${#type} - ${#unique_scopes} - 5))
  if [[ ${#summary_parts} -gt $max_desc_len ]]; then
    summary_parts="${summary_parts:0:$((max_desc_len - 3))}..."
  fi

  local title="${type}(${unique_scopes:-staging}): ${summary_parts}"

  # ── Build body with all individual commits ──
  # Each line is a full conventional commit subject so the pipeline can parse it
  printf '%s\n\n%s' "$title" "$commits"
}

# Attempt squash merge
if git merge --squash "origin/$DEV_BRANCH" >/dev/null 2>&1; then
  # Generate commit message from staged changes
  MERGE_MESSAGE=$(generate_commit_message "$DEV_BRANCH" "$STAGING_BRANCH")

  # Create merge commit
  if git commit -m "$MERGE_MESSAGE" >/dev/null 2>&1; then
    echo "✓ Squash merge completed" >&2

    # Get commit hash
    MERGE_HASH=$(git rev-parse HEAD)

    # Push to remote
    if git push origin "$STAGING_BRANCH" >/dev/null 2>&1; then
      echo "✓ Pushed to remote" >&2

      cat <<EOF
{
  "success": true,
  "merge_hash": "$MERGE_HASH",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "message": $(echo "$MERGE_MESSAGE" | head -1 | jq -Rs .),
  "pushed": true
}
EOF
      exit 0
    else
      echo "⚠️  Merge created but push failed" >&2

      cat <<EOF
{
  "success": false,
  "merge_hash": "$MERGE_HASH",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "error": "Failed to push merged branch"
}
EOF
      exit 2
    fi
  else
    echo "❌ Failed to create merge commit" >&2
    git merge --abort >/dev/null 2>&1 || true

    cat <<EOF
{
  "success": false,
  "error": "Failed to create merge commit"
}
EOF
    exit 1
  fi
else
  echo "❌ Merge conflict detected" >&2
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U)

  git merge --abort >/dev/null 2>&1 || true

  cat <<EOF
{
  "success": false,
  "conflict": true,
  "conflicting_files": [$(printf '"%s"' $CONFLICT_FILES | sed 's/""/,/g')],
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "error": "Merge conflicts detected"
}
EOF
  exit 1
fi

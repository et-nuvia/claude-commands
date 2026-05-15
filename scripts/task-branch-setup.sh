#!/usr/bin/env bash
# task-branch-setup.sh - Comprehensive task branch setup with automatic branch switching
# Usage: ./scripts/task-branch-setup.sh --input <task_doc_or_task_id>
# Returns: JSON with status and branch information
# Exit codes: 0=success, 1=error, 2=user_action_required

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"

# ============================================================================
# Configuration
# ============================================================================

TASK_INPUT=""
STASH_NAME=""
STASH_CREATED=false
ORIGINAL_BRANCH=""
DEV_BRANCH=""
TASK_BRANCH=""
ACTIONS_TAKEN=[]
ERRORS=[]
WARNINGS=[]

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) TASK_INPUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --input <task_doc_or_task_id>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TASK_INPUT" ]]; then
  echo '{"status":"error","message":"Usage: task-branch-setup.sh --input <task_doc_or_task_id>"}'
  exit 2
fi

log_action() {
  local action="$1"
  ACTIONS_TAKEN+=("\"$action\"")
}

log_error() {
  local error="$1"
  ERRORS+=("\"$error\"")
}

log_warning() {
  local warning="$1"
  WARNINGS+=("\"$warning\"")
}

# ============================================================================
# Helper Functions
# ============================================================================

# Prompt user for decision
prompt_user() {
  local prompt="$1"
  local options="$2"  # JSON array string like '["yes","no","abort"]'

  # Output prompt to stderr
  echo "" >&2
  echo "❓ $prompt" >&2
  echo "" >&2

  # Parse options and display
  local opts=($(echo "$options" | jq -r '.[]'))
  for i in "${!opts[@]}"; do
    echo "  $((i+1)). ${opts[$i]}" >&2
  done
  echo "" >&2

  # Read user choice
  read -p "Choice [1-${#opts[@]}]: " -r choice >&2

  # Validate and return choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#opts[@]} ]]; then
    echo "${opts[$((choice-1))]}"
    return 0
  else
    echo "abort"
    return 1
  fi
}

# Check if working directory is clean
is_working_dir_clean() {
  [[ -z "$(git status --porcelain)" ]]
}

# Get current branch
get_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# Check if branch exists locally
branch_exists_local() {
  local branch="$1"
  git rev-parse --verify "$branch" >/dev/null 2>&1
}

# Check if branch exists remotely
branch_exists_remote() {
  local branch="$1"
  git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch"
}

# ============================================================================
# Step 1: Parse Task Document
# ============================================================================

echo "🔍 Parsing task document..." >&2

TASK_DOC=""
TASK_ID=""
TYPE=""
SLUG=""
ISSUE_NUMBER=""

# Determine if input is task ID or path
if [[ "$TASK_INPUT" =~ ^[A-Fa-f0-9]{6}$ ]]; then
  # Input is task ID
  TASK_ID=$(normalize_task_id "$TASK_INPUT")
  TASK_DOC=$(find_primary "$TASK_ID")

  if [[ -z "$TASK_DOC" ]]; then
    echo "{\"status\":\"error\",\"message\":\"No task found for task ID $TASK_ID\"}"
    exit 1
  fi

  log_action "Found task document: $(basename "$TASK_DOC")"
elif [[ -f "$TASK_INPUT" ]]; then
  # Input is file path
  TASK_DOC="$TASK_INPUT"
  FILENAME=$(basename "$TASK_DOC")
  TASK_ID=$(get_task_id "$FILENAME")

  if [[ -z "$TASK_ID" ]]; then
    log_error "Could not extract task ID from filename: $FILENAME"
    echo "{\"status\":\"error\",\"message\":\"Invalid task document filename format\"}"
    exit 1
  fi
else
  echo "{\"status\":\"error\",\"message\":\"Invalid input: must be task ID or task document path\"}"
  exit 2
fi

# Extract task information
FILENAME=$(basename "$TASK_DOC")
TASK_ID=$(get_task_id "$FILENAME")
DOC_TYPE=$(get_type "$FILENAME")

# Extract slug from filename (description part)
SLUG=$(echo "$FILENAME" | sed -E 's/^[A-F0-9]{6}-[0-9]{10}-[A-Z]{3}-//' | sed 's/.md$//')
SLUG=$(echo "$SLUG" | head -c 40 | sed 's/-$//')

# Try to extract issue number from task document content
if [[ -f "$TASK_DOC" ]]; then
  ISSUE_NUMBER=$(grep -E '(GitHub|GitLab|Jira|Asana)' "$TASK_DOC" | sed -n 's/.*[#:]\([0-9]\+\).*/\1/p' | head -1 || echo "")
fi

# If no issue number, use task ID
if [[ -z "$ISSUE_NUMBER" ]]; then
  ISSUE_NUMBER="$TASK_ID"
fi

# Determine branch type from document type
case "$DOC_TYPE" in
  TSK|INC)
    # Try to infer from content or default to feature
    if grep -qi "bug\|fix" "$TASK_DOC"; then
      TYPE="fix"
    elif grep -qi "refactor" "$TASK_DOC"; then
      TYPE="refactor"
    elif grep -qi "test" "$TASK_DOC"; then
      TYPE="test"
    elif grep -qi "doc" "$TASK_DOC"; then
      TYPE="docs"
    else
      TYPE="feature"
    fi
    ;;
  FIX)
    TYPE="fix"
    ;;
  *)
    TYPE="feature"
    ;;
esac

# Generate task branch name
TASK_BRANCH="${TYPE}/${ISSUE_NUMBER}-${SLUG}"

log_action "Calculated task branch: $TASK_BRANCH"

echo "  Task: $TASK_ID ($DOC_TYPE)" >&2
echo "  Branch: $TASK_BRANCH" >&2

# ============================================================================
# Step 2: Get Current Branch
# ============================================================================

ORIGINAL_BRANCH=$(get_current_branch)

if [[ -z "$ORIGINAL_BRANCH" ]]; then
  log_error "Not in a git repository"
  echo "{\"status\":\"error\",\"message\":\"Not in a git repository\"}"
  exit 1
fi

log_action "Current branch: $ORIGINAL_BRANCH"
echo "  Current branch: $ORIGINAL_BRANCH" >&2

# Check if already on task branch
if [[ "$ORIGINAL_BRANCH" == "$TASK_BRANCH" ]]; then
  echo "✅ Already on task branch" >&2

  # Check if working directory is clean
  if ! is_working_dir_clean; then
    log_warning "Working directory has uncommitted changes"
  fi

  cat <<EOF
{
  "status": "success",
  "message": "Already on task branch",
  "original_branch": "$ORIGINAL_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "branch_switched": false,
  "stash_created": false,
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "warnings": [$(IFS=,; echo "${WARNINGS[*]:-}")],
  "task": {
    "task_id": "$TASK_ID",
    "type": "$DOC_TYPE",
    "issue_number": "$ISSUE_NUMBER",
    "document": "$TASK_DOC"
  }
}
EOF
  exit 0
fi

# ============================================================================
# Step 3: Check Working Directory and Stash if Needed
# ============================================================================

echo "" >&2
echo "📦 Checking working directory..." >&2

if ! is_working_dir_clean; then
  echo "  ⚠️  Uncommitted changes detected" >&2

  # Show status
  echo "" >&2
  git status --short >&2
  echo "" >&2

  # Prompt user
  choice=$(prompt_user "Uncommitted changes detected. What would you like to do?" '["stash","abort"]')

  if [[ "$choice" == "abort" ]]; then
    log_action "User aborted due to uncommitted changes"
    cat <<EOF
{
  "status": "aborted",
  "message": "User aborted due to uncommitted changes",
  "original_branch": "$ORIGINAL_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "warnings": [$(IFS=,; echo "${WARNINGS[*]:-}")]
}
EOF
    exit 2
  fi

  # Stash changes
  STASH_NAME="task-branch-setup: switching from $ORIGINAL_BRANCH to $TASK_BRANCH ($(date +%Y-%m-%d_%H:%M:%S))"

  echo "  📦 Stashing changes..." >&2
  if git stash push -m "$STASH_NAME" >/dev/null 2>&1; then
    STASH_CREATED=true
    log_action "Stashed changes: $STASH_NAME"
    echo "  ✓ Changes stashed" >&2
  else
    log_error "Failed to stash changes"
    cat <<EOF
{
  "status": "error",
  "message": "Failed to stash changes",
  "original_branch": "$ORIGINAL_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
    exit 1
  fi
else
  log_action "Working directory is clean"
  echo "  ✓ Working directory is clean" >&2
fi

# ============================================================================
# Step 4: Determine Dev Branch
# ============================================================================

echo "" >&2
echo "🌿 Determining dev branch..." >&2

# Use get-default-branch.sh to get dev branch
if [[ -f "${SCRIPT_DIR}/get-default-branch.sh" ]]; then
  DEV_BRANCH=$("${SCRIPT_DIR}/get-default-branch.sh" 2>/dev/null || echo "")
fi

if [[ -z "$DEV_BRANCH" ]]; then
  # Fallback: try to get from PROJECT.yaml
  if [[ -f "PROJECT.yaml" ]] && command -v yq >/dev/null 2>&1; then
    DEV_BRANCH=$(yaml_get '.ci.branches.dev' PROJECT.yaml)
  fi
fi

if [[ -z "$DEV_BRANCH" ]]; then
  # Final fallback: common defaults
  for branch in dev develop development main master; do
    if branch_exists_local "$branch" || branch_exists_remote "$branch"; then
      DEV_BRANCH="$branch"
      break
    fi
  done
fi

if [[ -z "$DEV_BRANCH" ]]; then
  log_error "Could not determine dev branch"

  # Restore stash if created
  if [[ "$STASH_CREATED" == "true" ]]; then
    git stash pop >/dev/null 2>&1 || true
  fi

  cat <<EOF
{
  "status": "error",
  "message": "Could not determine dev branch",
  "original_branch": "$ORIGINAL_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
  exit 1
fi

log_action "Dev branch: $DEV_BRANCH"
echo "  Dev branch: $DEV_BRANCH" >&2

# ============================================================================
# Step 5: Fetch from Remote
# ============================================================================

echo "" >&2
echo "🔄 Fetching from remote..." >&2

if git fetch origin >/dev/null 2>&1; then
  log_action "Fetched from remote"
  echo "  ✓ Fetched latest from origin" >&2
else
  log_warning "Failed to fetch from remote (continuing anyway)"
  echo "  ⚠️  Could not fetch from remote" >&2
fi

# ============================================================================
# Step 6: Switch to Dev Branch
# ============================================================================

echo "" >&2
echo "🌿 Switching to dev branch ($DEV_BRANCH)..." >&2

if [[ "$ORIGINAL_BRANCH" != "$DEV_BRANCH" ]]; then
  # Check if dev branch exists
  DEV_EXISTS_LOCAL=$(branch_exists_local "$DEV_BRANCH" && echo "true" || echo "false")
  DEV_EXISTS_REMOTE=$(branch_exists_remote "$DEV_BRANCH" && echo "true" || echo "false")

  if [[ "$DEV_EXISTS_LOCAL" == "true" ]]; then
    # Checkout existing local branch
    if git checkout "$DEV_BRANCH" >/dev/null 2>&1; then
      log_action "Checked out dev branch: $DEV_BRANCH"
      echo "  ✓ Checked out $DEV_BRANCH" >&2
    else
      log_error "Failed to checkout dev branch: $DEV_BRANCH"

      # Restore stash if created
      if [[ "$STASH_CREATED" == "true" ]]; then
        git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
        git stash pop >/dev/null 2>&1 || true
      fi

      cat <<EOF
{
  "status": "error",
  "message": "Failed to checkout dev branch: $DEV_BRANCH",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
      exit 1
    fi
  elif [[ "$DEV_EXISTS_REMOTE" == "true" ]]; then
    # Fetch and checkout from remote
    if git checkout -b "$DEV_BRANCH" "origin/$DEV_BRANCH" >/dev/null 2>&1; then
      log_action "Checked out dev branch from remote: $DEV_BRANCH"
      echo "  ✓ Checked out $DEV_BRANCH from remote" >&2
    else
      log_error "Failed to checkout dev branch from remote: $DEV_BRANCH"

      # Restore stash if created
      if [[ "$STASH_CREATED" == "true" ]]; then
        git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
        git stash pop >/dev/null 2>&1 || true
      fi

      cat <<EOF
{
  "status": "error",
  "message": "Failed to checkout dev branch from remote: $DEV_BRANCH",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
      exit 1
    fi
  else
    log_error "Dev branch does not exist: $DEV_BRANCH"

    # Restore stash if created
    if [[ "$STASH_CREATED" == "true" ]]; then
      git stash pop >/dev/null 2>&1 || true
    fi

    cat <<EOF
{
  "status": "error",
  "message": "Dev branch does not exist: $DEV_BRANCH",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
    exit 1
  fi
else
  log_action "Already on dev branch"
  echo "  ✓ Already on dev branch" >&2
fi

# ============================================================================
# Step 7: Pull Latest Changes on Dev Branch
# ============================================================================

echo "" >&2
echo "⬇️  Pulling latest changes on $DEV_BRANCH..." >&2

if git pull origin "$DEV_BRANCH" >/dev/null 2>&1; then
  log_action "Pulled latest changes from origin/$DEV_BRANCH"
  echo "  ✓ Pulled latest changes" >&2
else
  log_warning "Could not pull latest changes (continuing anyway)"
  echo "  ⚠️  Could not pull latest changes" >&2
fi

# ============================================================================
# Step 8: Create or Checkout Task Branch
# ============================================================================

echo "" >&2
echo "🎯 Setting up task branch ($TASK_BRANCH)..." >&2

TASK_EXISTS_LOCAL=$(branch_exists_local "$TASK_BRANCH" && echo "true" || echo "false")
TASK_EXISTS_REMOTE=$(branch_exists_remote "$TASK_BRANCH" && echo "true" || echo "false")

if [[ "$TASK_EXISTS_LOCAL" == "true" ]]; then
  # Checkout existing local branch
  if git checkout "$TASK_BRANCH" >/dev/null 2>&1; then
    log_action "Checked out existing task branch: $TASK_BRANCH"
    echo "  ✓ Checked out existing branch" >&2
  else
    log_error "Failed to checkout task branch: $TASK_BRANCH"

    # Restore state
    git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
    if [[ "$STASH_CREATED" == "true" ]]; then
      git stash pop >/dev/null 2>&1 || true
    fi

    cat <<EOF
{
  "status": "error",
  "message": "Failed to checkout task branch: $TASK_BRANCH",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
    exit 1
  fi
elif [[ "$TASK_EXISTS_REMOTE" == "true" ]]; then
  # Fetch and checkout from remote
  if git checkout -b "$TASK_BRANCH" "origin/$TASK_BRANCH" >/dev/null 2>&1; then
    log_action "Checked out task branch from remote: $TASK_BRANCH"
    echo "  ✓ Checked out branch from remote" >&2
  else
    log_error "Failed to checkout task branch from remote: $TASK_BRANCH"

    # Restore state
    git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
    if [[ "$STASH_CREATED" == "true" ]]; then
      git stash pop >/dev/null 2>&1 || true
    fi

    cat <<EOF
{
  "status": "error",
  "message": "Failed to checkout task branch from remote: $TASK_BRANCH",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
    exit 1
  fi
else
  # Create new branch
  if git checkout -b "$TASK_BRANCH" >/dev/null 2>&1; then
    log_action "Created new task branch: $TASK_BRANCH"
    echo "  ✓ Created new branch" >&2
  else
    log_error "Failed to create task branch: $TASK_BRANCH"

    # Restore state
    git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
    if [[ "$STASH_CREATED" == "true" ]]; then
      git stash pop >/dev/null 2>&1 || true
    fi

    cat <<EOF
{
  "status": "error",
  "message": "Failed to create task branch: $TASK_BRANCH",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")]
}
EOF
    exit 1
  fi
fi

# ============================================================================
# Step 9: Restore Stash if Created
# ============================================================================

if [[ "$STASH_CREATED" == "true" ]]; then
  echo "" >&2
  echo "📦 Restoring stashed changes..." >&2

  if git stash pop >/dev/null 2>&1; then
    log_action "Restored stashed changes"
    echo "  ✓ Changes restored" >&2
  else
    log_warning "Failed to restore stashed changes (conflicts may exist)"
    echo "  ⚠️  Could not auto-restore stash" >&2
    echo "" >&2
    echo "Stash still available: $STASH_NAME" >&2
    echo "Manually apply with: git stash apply" >&2
    echo "" >&2

    # Prompt user
    choice=$(prompt_user "Failed to restore stashed changes. Conflicts may exist." '["resolve_manually","abort"]')

    if [[ "$choice" == "abort" ]]; then
      # Try to restore original state
      git reset --hard >/dev/null 2>&1 || true
      git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true

      cat <<EOF
{
  "status": "error",
  "message": "Failed to restore stashed changes - conflicts exist",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "stash_name": "$STASH_NAME",
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "errors": [$(IFS=,; echo "${ERRORS[*]}")],
  "warnings": [$(IFS=,; echo "${WARNINGS[*]:-}")]
}
EOF
      exit 1
    fi

    # User chose to resolve manually
    log_warning "User will resolve stash conflicts manually"
  fi
fi

# ============================================================================
# Step 10: Output Success JSON
# ============================================================================

echo "" >&2
echo "✅ Task branch setup complete!" >&2
echo "  From: $ORIGINAL_BRANCH" >&2
echo "  To: $TASK_BRANCH" >&2

cat <<EOF
{
  "status": "success",
  "message": "Task branch setup complete",
  "original_branch": "$ORIGINAL_BRANCH",
  "dev_branch": "$DEV_BRANCH",
  "task_branch": "$TASK_BRANCH",
  "branch_switched": true,
  "stash_created": $STASH_CREATED,
  "stash_name": "$STASH_NAME",
  "task": {
    "task_id": "$TASK_ID",
    "type": "$DOC_TYPE",
    "branch_type": "$TYPE",
    "issue_number": "$ISSUE_NUMBER",
    "slug": "$SLUG",
    "document": "$TASK_DOC"
  },
  "actions": [$(IFS=,; echo "${ACTIONS_TAKEN[*]}")],
  "warnings": [$(IFS=,; echo "${WARNINGS[*]:-}")]
}
EOF

exit 0
